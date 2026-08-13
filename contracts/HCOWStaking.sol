// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title HCOWStaking
 * @notice Delegated staking. A holder delegates HCOW to one representative,
 *         rewards are funded in HCOW and split across representatives by
 *         delegated weight, and each representative keeps a commission.
 *
 * WHAT THE CHAIN ENFORCES
 *   - Commission is capped at MAX_COMMISSION_BPS and checked on every write.
 *     A representative cannot raise it past the cap, ever.
 *   - Rewards are funded, never minted. HCOW has a fixed supply and no mint
 *     function, so every reward paid here was transferred in first. The
 *     contract can only distribute what it actually holds.
 *   - A delegator is delegated to exactly one representative. Moving requires
 *     redelegate, which settles rewards first, so nothing is stranded.
 *   - Unstaking has a cooldown. The amount leaves the earning set the moment
 *     it is requested, so a leaving delegator neither earns nor blocks.
 *   - Staked principal is never consumed here. That mechanism belongs to
 *     Profit Share and mixing the two would make both harder to reason about.
 *
 * A NOTE ON NAMING
 *   HCOW is a token on BNB Chain, not its own network. Nothing here secures a
 *   chain or produces blocks. The contract does what it says: it records
 *   delegations, splits funded rewards, and pays commission. Any external
 *   description should match that.
 */
contract HCOWStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Hard ceiling on representative commission. 10%.
    uint16 public constant MAX_COMMISSION_BPS = 1000;

    /// @notice Wait between requesting an unstake and being able to withdraw.
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    uint256 private constant ACC_PRECISION = 1e18;

    IERC20 public immutable hcow;

    address public owner;
    address public rewardFunder;

    struct Representative {
        address payout;            // receives commission
        uint16  commissionBps;     // <= MAX_COMMISSION_BPS
        bool    active;            // inactive reps receive no new rewards
        bool    isFoundation;
        bool    exists;
        uint256 totalDelegated;
        uint256 delegatorCount;
        uint256 accRewardPerShare;
        uint256 commissionAccrued;
        uint256 lifetimeRewards;   // delegator rewards routed through this rep
        string  name;
    }

    struct Delegation {
        bytes32 repId;
        uint128 amount;
        uint128 pendingUnstake;
        uint64  unstakeReadyAt;
        uint256 rewardDebt;
        uint256 claimable;
        uint256 lifetimeClaimed;
    }

    mapping(bytes32 => Representative) private _reps;
    bytes32[] private _repIds;
    mapping(address => Delegation) private _delegations;

    /// @notice HCOW delegated across every representative, active or not.
    uint256 public totalStaked;
    /// @notice HCOW held for pending unstakes. Not earning, not distributable.
    uint256 public totalPendingUnstake;
    /// @notice HCOW held to pay accrued delegator rewards and commission.
    uint256 public totalRewardsOwed;
    uint256 public totalRewardsFunded;

    event RepresentativeRegistered(bytes32 indexed id, string name, address payout, uint16 commissionBps, bool isFoundation);
    event RepresentativeUpdated(bytes32 indexed id, address payout, uint16 commissionBps, bool active);
    event Staked(address indexed account, bytes32 indexed repId, uint256 amount);
    event Redelegated(address indexed account, bytes32 indexed fromRep, bytes32 indexed toRep, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt);
    event UnstakeCancelled(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event CommissionClaimed(bytes32 indexed repId, address indexed payout, uint256 amount);
    event RewardsFunded(uint256 amount, uint256 activeWeight, uint256 activeReps);
    event RewardFunderChanged(address indexed account);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotFunder();
    error ZeroAddress();
    error ZeroAmount();
    error UnknownRepresentative(bytes32 id);
    error RepresentativeExists(bytes32 id);
    error RepresentativeInactive(bytes32 id);
    error CommissionTooHigh(uint16 given, uint16 max);
    error AlreadyDelegatedElsewhere(bytes32 current);
    error NothingStaked();
    error InsufficientStake(uint256 requested, uint256 available);
    error UnstakeAlreadyPending();
    error NoPendingUnstake();
    error CooldownActive(uint64 readyAt);
    error NothingToClaim();
    error NoActiveWeight();
    error SameRepresentative();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address hcowToken, address initialOwner, address initialFunder) {
        if (hcowToken == address(0) || initialOwner == address(0) || initialFunder == address(0)) {
            revert ZeroAddress();
        }
        hcow = IERC20(hcowToken);
        owner = initialOwner;
        rewardFunder = initialFunder;
        emit OwnershipTransferred(address(0), initialOwner);
        emit RewardFunderChanged(initialFunder);
    }

    // ------------------------------------------------------------------
    // representative registry
    // ------------------------------------------------------------------

    function registerRepresentative(
        bytes32 id,
        string calldata name,
        address payout,
        uint16 commissionBps,
        bool isFoundation
    ) external onlyOwner {
        if (id == bytes32(0) || payout == address(0)) revert ZeroAddress();
        if (_reps[id].exists) revert RepresentativeExists(id);
        if (commissionBps > MAX_COMMISSION_BPS) {
            revert CommissionTooHigh(commissionBps, MAX_COMMISSION_BPS);
        }

        Representative storage r = _reps[id];
        r.payout = payout;
        r.commissionBps = commissionBps;
        r.active = true;
        r.isFoundation = isFoundation;
        r.exists = true;
        r.name = name;
        _repIds.push(id);

        emit RepresentativeRegistered(id, name, payout, commissionBps, isFoundation);
    }

    function updateRepresentative(bytes32 id, address payout, uint16 commissionBps, bool active)
        external
        onlyOwner
    {
        Representative storage r = _reps[id];
        if (!r.exists) revert UnknownRepresentative(id);
        if (payout == address(0)) revert ZeroAddress();
        if (commissionBps > MAX_COMMISSION_BPS) {
            revert CommissionTooHigh(commissionBps, MAX_COMMISSION_BPS);
        }
        r.payout = payout;
        r.commissionBps = commissionBps;
        r.active = active;
        emit RepresentativeUpdated(id, payout, commissionBps, active);
    }

    // ------------------------------------------------------------------
    // delegator actions
    // ------------------------------------------------------------------

    /// @notice Delegate HCOW to a representative. Adding to an existing
    ///         delegation is allowed only for the same representative.
    function stake(uint256 amount, bytes32 repId) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Representative storage r = _reps[repId];
        if (!r.exists) revert UnknownRepresentative(repId);
        if (!r.active) revert RepresentativeInactive(repId);

        Delegation storage d = _delegations[msg.sender];
        if (d.amount > 0 && d.repId != repId) revert AlreadyDelegatedElsewhere(d.repId);

        _harvest(d);

        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        if (d.amount == 0) {
            d.repId = repId;
            r.delegatorCount += 1;
        }
        d.amount += uint128(received);
        r.totalDelegated += received;
        totalStaked += received;

        d.rewardDebt = (uint256(d.amount) * r.accRewardPerShare) / ACC_PRECISION;
        emit Staked(msg.sender, repId, received);
    }

    /// @notice Move the whole delegation to another representative.
    function redelegate(bytes32 toRepId) external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        if (d.amount == 0) revert NothingStaked();
        bytes32 fromId = d.repId;
        if (fromId == toRepId) revert SameRepresentative();

        Representative storage to = _reps[toRepId];
        if (!to.exists) revert UnknownRepresentative(toRepId);
        if (!to.active) revert RepresentativeInactive(toRepId);

        // Settle against the old representative before the weight moves,
        // otherwise the delegator loses rewards already earned there.
        _harvest(d);

        Representative storage from = _reps[fromId];
        uint256 amount = d.amount;
        from.totalDelegated -= amount;
        from.delegatorCount -= 1;

        d.repId = toRepId;
        to.totalDelegated += amount;
        to.delegatorCount += 1;
        d.rewardDebt = (amount * to.accRewardPerShare) / ACC_PRECISION;

        emit Redelegated(msg.sender, fromId, toRepId, amount);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Delegation storage d = _delegations[msg.sender];
        if (d.unstakeReadyAt != 0) revert UnstakeAlreadyPending();
        if (d.amount == 0) revert NothingStaked();
        if (amount > d.amount) revert InsufficientStake(amount, d.amount);

        _harvest(d);

        Representative storage r = _reps[d.repId];
        d.amount -= uint128(amount);
        r.totalDelegated -= amount;
        totalStaked -= amount;

        if (d.amount == 0) r.delegatorCount -= 1;

        d.pendingUnstake = uint128(amount);
        d.unstakeReadyAt = uint64(block.timestamp + UNSTAKE_COOLDOWN);
        totalPendingUnstake += amount;

        d.rewardDebt = (uint256(d.amount) * r.accRewardPerShare) / ACC_PRECISION;
        emit UnstakeRequested(msg.sender, amount, d.unstakeReadyAt);
    }

    function cancelUnstake() external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        if (d.unstakeReadyAt == 0) revert NoPendingUnstake();

        Representative storage r = _reps[d.repId];
        if (!r.active) revert RepresentativeInactive(d.repId);

        _harvest(d);

        uint256 amount = d.pendingUnstake;
        d.pendingUnstake = 0;
        d.unstakeReadyAt = 0;
        totalPendingUnstake -= amount;

        if (d.amount == 0) r.delegatorCount += 1;
        d.amount += uint128(amount);
        r.totalDelegated += amount;
        totalStaked += amount;

        d.rewardDebt = (uint256(d.amount) * r.accRewardPerShare) / ACC_PRECISION;
        emit UnstakeCancelled(msg.sender, amount);
    }

    function withdrawUnstaked() external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        if (d.unstakeReadyAt == 0) revert NoPendingUnstake();
        if (block.timestamp < d.unstakeReadyAt) revert CooldownActive(d.unstakeReadyAt);

        uint256 amount = d.pendingUnstake;
        d.pendingUnstake = 0;
        d.unstakeReadyAt = 0;
        totalPendingUnstake -= amount;

        hcow.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimHcow() external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        _harvest(d);

        uint256 amount = d.claimable;
        if (amount == 0) revert NothingToClaim();
        d.claimable = 0;
        d.lifetimeClaimed += amount;
        totalRewardsOwed -= amount;

        hcow.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Anyone may trigger a payout, but it only ever goes to the
    ///         representative's registered payout address.
    function claimCommission(bytes32 repId) external nonReentrant {
        Representative storage r = _reps[repId];
        if (!r.exists) revert UnknownRepresentative(repId);

        uint256 amount = r.commissionAccrued;
        if (amount == 0) revert NothingToClaim();
        r.commissionAccrued = 0;
        totalRewardsOwed -= amount;

        hcow.safeTransfer(r.payout, amount);
        emit CommissionClaimed(repId, r.payout, amount);
    }

    // ------------------------------------------------------------------
    // rewards
    // ------------------------------------------------------------------

    /**
     * @notice Fund a reward round. Split across active representatives in
     *         proportion to delegated weight; each takes its commission and the
     *         remainder goes to its delegators.
     * @dev HCOW cannot be minted, so the funder must hold and approve the
     *      tokens. Nothing is created here.
     */
    function fundRewards(uint256 amount) external nonReentrant {
        if (msg.sender != rewardFunder) revert NotFunder();
        if (amount == 0) revert ZeroAmount();

        uint256 activeWeight;
        uint256 activeCount;
        uint256 n = _repIds.length;
        for (uint256 i = 0; i < n; ++i) {
            Representative storage r = _reps[_repIds[i]];
            if (r.active && r.totalDelegated > 0) {
                activeWeight += r.totalDelegated;
                activeCount += 1;
            }
        }
        if (activeWeight == 0) revert NoActiveWeight();

        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        uint256 handedOut;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = _repIds[i];
            Representative storage r = _reps[id];
            if (!r.active || r.totalDelegated == 0) continue;

            uint256 slice = (received * r.totalDelegated) / activeWeight;
            if (slice == 0) continue;
            handedOut += slice;

            uint256 commission = (slice * r.commissionBps) / 10_000;
            uint256 toDelegators = slice - commission;

            r.commissionAccrued += commission;
            r.accRewardPerShare += (toDelegators * ACC_PRECISION) / r.totalDelegated;
            r.lifetimeRewards += toDelegators;
        }

        // Rounding dust stays in the contract and is picked up by the next
        // round, rather than being stranded or silently pocketed.
        totalRewardsOwed += handedOut;
        totalRewardsFunded += received;

        emit RewardsFunded(received, activeWeight, activeCount);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function pendingRewardOf(address account) public view returns (uint256) {
        Delegation storage d = _delegations[account];
        if (d.amount == 0) return d.claimable;
        uint256 accrued = (uint256(d.amount) * _reps[d.repId].accRewardPerShare) / ACC_PRECISION;
        return d.claimable + (accrued > d.rewardDebt ? accrued - d.rewardDebt : 0);
    }

    function delegationOf(address account)
        external
        view
        returns (
            bytes32 repId,
            uint256 stakedAmount,
            uint256 pendingUnstake,
            uint64 unstakeReadyAt,
            uint256 pendingReward,
            uint256 lifetimeClaimed
        )
    {
        Delegation storage d = _delegations[account];
        return (d.repId, d.amount, d.pendingUnstake, d.unstakeReadyAt,
                pendingRewardOf(account), d.lifetimeClaimed);
    }

    function representativeOf(bytes32 id)
        external
        view
        returns (
            string memory name,
            address payout,
            uint16 commissionBps,
            bool active,
            bool isFoundation,
            uint256 totalDelegated,
            uint256 delegatorCount,
            uint256 commissionAccrued
        )
    {
        Representative storage r = _reps[id];
        if (!r.exists) revert UnknownRepresentative(id);
        return (r.name, r.payout, r.commissionBps, r.active, r.isFoundation,
                r.totalDelegated, r.delegatorCount, r.commissionAccrued);
    }

    function representativeIds() external view returns (bytes32[] memory) {
        return _repIds;
    }

    function representativeCount() external view returns (uint256 total, uint256 active) {
        uint256 n = _repIds.length;
        total = n;
        for (uint256 i = 0; i < n; ++i) {
            if (_reps[_repIds[i]].active) active += 1;
        }
    }

    // ------------------------------------------------------------------
    // administration
    // ------------------------------------------------------------------

    function setRewardFunder(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        rewardFunder = account;
        emit RewardFunderChanged(account);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ------------------------------------------------------------------
    // internal
    // ------------------------------------------------------------------

    function _harvest(Delegation storage d) private {
        if (d.amount > 0) {
            uint256 accrued = (uint256(d.amount) * _reps[d.repId].accRewardPerShare) / ACC_PRECISION;
            if (accrued > d.rewardDebt) {
                d.claimable += accrued - d.rewardDebt;
            }
            d.rewardDebt = accrued;
        }
    }
}
