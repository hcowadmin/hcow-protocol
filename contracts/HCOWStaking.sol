// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
 *   - The active flag gates new delegations only. It does not stop accrual:
 *     stranding a delegator mid cooldown for a decision the owner made about
 *     their representative was never what the flag was for.
 *   - Staked principal is never consumed here. That mechanism belongs to
 *     Profit Share and mixing the two would make both harder to reason about.
 *
 * A NOTE ON NAMING
 *   HCOW is a token on BNB Chain, not its own network. Nothing here secures a
 *   chain or produces blocks. The contract does what it says: it records
 *   delegations, streams funded rewards, and pays commission. Any external
 *   description should match that.
 */
contract HCOWStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Hard ceiling on representative commission. 10%.
    uint16 public constant MAX_COMMISSION_BPS = 1000;

    /**
     * @notice Ceiling on registered representatives.
     *
     * Funding is O(1) now, so this is no longer about the cost of a reward
     * round. It bounds representativeCount(), which is an unbounded view loop,
     * and it keeps the set small enough to be published and checked by hand.
     * Deregistration is not offered because a representative with live
     * delegations cannot safely disappear.
     */
    uint256 public constant MAX_REPRESENTATIVES = 100;

    /**
     * @notice Below this, a released second is carried instead of distributed.
     *
     * The accumulator advances by released over totalStaked, so a pool of a
     * few wei inflates it without bound and every later position is priced
     * against it. Past a point an ordinary sized stake can no longer be
     * harvested at all, and its principal is stuck on a contract that cannot
     * be upgraded. mulDiv removes the overflow; this removes the reason to go
     * looking for it, and a pool this small has no claim on a reward stream.
     */
    uint256 public constant MIN_STAKE_FOR_ACCRUAL = 1e18;

    /// @notice Wait between requesting an unstake and being able to withdraw.
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    /**
     * @notice Accumulator precision.
     *
     * The accumulator advances by `released * ACC_PRECISION / totalStaked`, so
     * its granularity is `totalStaked / ACC_PRECISION` wei per call and
     * anything finer is not claimable by anyone. At 1e18 against an 18 decimal
     * token a slow stream over a large pool strands a real fraction of it,
     * with no way to recover it. Every product this appears in is divided
     * before being multiplied again, so the extra six orders cost nothing in
     * headroom.
     */
    uint256 private constant ACC_PRECISION = 1e24;

    IERC20 public immutable hcow;

    address public owner;
    address public rewardFunder;

    struct Representative {
        address payout;            // receives commission
        uint16  commissionBps;     // <= MAX_COMMISSION_BPS
        bool    active;            // gates NEW delegations, not accrual
        bool    isFoundation;
        bool    exists;
        uint256 totalDelegated;
        uint256 delegatorCount;
        /// Accounts with nothing staked here but a pending unstake that can
        /// still be cancelled back into it. They hold no weight, so the three
        /// balance figures all read empty while the record is still in use.
        uint256 pendingDelegators;
        /// Net-of-commission accumulator, frozen at the last commission change.
        uint256 accNetBase;
        /// Global accumulator at that same moment.
        uint256 accNetAnchor;
        /// Global accumulator when commission was last folded into the total
        /// below. Separate from the net anchor because commission is an
        /// aggregate over the representative's weight, not a per share figure.
        uint256 commAnchor;
        uint256 commissionAccrued;
        uint256 lifetimeRewards;   // delegator rewards routed through this rep
        string  name;
    }

    struct Delegation {
        bytes32 repId;
        uint128 amount;
        uint128 pendingUnstake;
        uint64  unstakeReadyAt;
        uint256 rewardDebtNet;    // bookmark on the representative's net one
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
    /// @dev Advanced by _updateGlobal and reduced by claims. Read it through
    ///      totalRewardsOwed(), which also counts the seconds that have
    ///      elapsed since the last state changing call.
    uint256 private _rewardsOwed;
    uint256 public totalRewardsFunded;

    /**
     * @notice Rewards accrue per second, not in lumps.
     *
     * A lump sum split by whoever happens to be staked at the instant of
     * funding pays a position that has been there for one block exactly what
     * it pays a position that has been there all quarter. That is not a
     * rounding problem, it is the whole reward budget going to whoever has the
     * most idle HCOW at the right moment. It also makes commission optional:
     * redelegating to a zero commission representative for one block costs
     * nothing. Accruing per second removes both, because there is no moment to
     * jump into or out of.
     */
    uint256 public accRewardPerShare;
    uint256 public rewardRate;      // HCOW per second for the current period
    uint64  public periodFinish;    // when the current period runs out
    uint64  public lastUpdateTime;

    /// @notice Funded HCOW that elapsed while nothing was staked. Nobody was
    ///         owed it, so it is carried into the next funding rather than
    ///         stranded.
    uint256 public undistributed;

    /// @notice Shortest and longest a funding period may run.
    uint64 public constant MIN_REWARD_DURATION = 1 days;
    uint64 public constant MAX_REWARD_DURATION = 365 days;

    event RepresentativeRegistered(bytes32 indexed id, string name, address payout, uint16 commissionBps, bool isFoundation);
    event RepresentativeUpdated(bytes32 indexed id, address payout, uint16 commissionBps, bool active);
    event RepresentativeDeregistered(bytes32 indexed id);
    event Staked(address indexed account, bytes32 indexed repId, uint256 amount);
    event Redelegated(address indexed account, bytes32 indexed fromRep, bytes32 indexed toRep, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt);
    event UnstakeCancelled(address indexed account, bytes32 indexed repId, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event CommissionClaimed(bytes32 indexed repId, address indexed payout, uint256 amount);
    event RewardsFunded(uint256 amount, uint256 rewardRate, uint64 duration);
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
    error SameRepresentative();
    error TooManyRepresentatives(uint256 max);
    error RepresentativeNotEmpty(bytes32 id);
    error BadDuration(uint64 given);

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
        // An id can be deregistered and registered again. Nothing from the
        // previous life may survive: accNetBase in particular would silently
        // wipe an existing delegator's accrued rewards.
        r.accNetBase = 0;
        r.totalDelegated = 0;
        r.delegatorCount = 0;
        r.pendingDelegators = 0;
        r.commissionAccrued = 0;
        r.lifetimeRewards = 0;
        _updateGlobal();
        r.accNetAnchor = accRewardPerShare;
        r.commAnchor = accRewardPerShare;
        if (_repIds.length >= MAX_REPRESENTATIVES) {
            revert TooManyRepresentatives(MAX_REPRESENTATIVES);
        }
        _repIds.push(id);

        emit RepresentativeRegistered(id, name, payout, commissionBps, isFoundation);
    }

    /**
     * @notice Remove a representative that holds nothing.
     * @dev The cap is permanent otherwise: a typo'd id, a test entry, or
     *      ordinary churn would consume slots for good on a contract that
     *      cannot be upgraded. Only an empty record may go, which is exactly
     *      the safety property that made deregistration unsafe in general.
     */
    function deregisterRepresentative(bytes32 id) external onlyOwner nonReentrant {
        Representative storage r = _reps[id];
        if (!r.exists) revert UnknownRepresentative(id);
        _updateGlobal();
        _accrueRepCommission(r);
        if (
            r.totalDelegated != 0 || r.delegatorCount != 0
            || r.commissionAccrued != 0 || r.pendingDelegators != 0
        ) {
            revert RepresentativeNotEmpty(id);
        }

        // Locate first, mutate after. Writing inside the loop is the same
        // work but reads as an unbounded cost to a static analyser, and to a
        // reviewer.
        uint256 n = _repIds.length;
        uint256 at = n;
        for (uint256 i = 0; i < n; ++i) {
            if (_repIds[i] == id) { at = i; break; }
        }
        if (at < n) {
            _repIds[at] = _repIds[n - 1];
            _repIds.pop();
        }
        delete _reps[id];
        emit RepresentativeDeregistered(id);
    }

    function updateRepresentative(bytes32 id, address payout, uint16 commissionBps, bool active)
        external
        onlyOwner
        nonReentrant
    {
        Representative storage r = _reps[id];
        if (!r.exists) revert UnknownRepresentative(id);
        if (payout == address(0)) revert ZeroAddress();
        if (commissionBps > MAX_COMMISSION_BPS) {
            revert CommissionTooHigh(commissionBps, MAX_COMMISSION_BPS);
        }

        // Commission already earned belongs to the address that earned it.
        // Settling here means repointing payout can never redirect a balance
        // that accrued under the previous one, which would otherwise let the
        // owner take a representative's accrued commission outright.
        // Advance the stream and freeze this representative's net accumulator
        // at the commission that was actually in force, so a change applies
        // only from here on.
        _updateGlobal();
        _accrueRepCommission(r);
        _freezeCommission(r);

        address oldPayout = r.payout;
        uint256 owed = (payout != oldPayout) ? r.commissionAccrued : 0;

        // Effects first. The transfer below is the only external call and it
        // must not run with a half-applied representative record behind it.
        if (owed > 0) {
            r.commissionAccrued = 0;
            _rewardsOwed = owed > _rewardsOwed ? 0 : _rewardsOwed - owed;
        }
        r.payout = payout;
        r.commissionBps = commissionBps;
        r.active = active;

        if (owed > 0) {
            hcow.safeTransfer(oldPayout, owed);
            emit CommissionClaimed(id, oldPayout, owed);
        }
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
        _accrueRepCommission(r);

        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        if (d.amount == 0) {
            d.repId = repId;
            r.delegatorCount += 1;
        }
        d.amount += received.toUint128();
        r.totalDelegated += received;
        totalStaked += received;

        _bookmark(d, r);
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
        _accrueRepCommission(from);
        _accrueRepCommission(to);
        uint256 amount = d.amount;
        from.totalDelegated -= amount;
        from.delegatorCount -= 1;

        d.repId = toRepId;
        to.totalDelegated += amount;
        to.delegatorCount += 1;
        _bookmark(d, to);

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
        _accrueRepCommission(r);
        d.amount -= amount.toUint128();
        r.totalDelegated -= amount;
        totalStaked -= amount;

        if (d.amount == 0) {
            r.delegatorCount -= 1;
            // Still pointing here: cancelUnstake can put it back.
            r.pendingDelegators += 1;
        }

        d.pendingUnstake = amount.toUint128();
        d.unstakeReadyAt = uint64(block.timestamp + UNSTAKE_COOLDOWN);
        totalPendingUnstake += amount;

        _bookmark(d, r);
        emit UnstakeRequested(msg.sender, amount, d.unstakeReadyAt);
    }

    function cancelUnstake() external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        if (d.unstakeReadyAt == 0) revert NoPendingUnstake();

        // Deliberately not gated on r.active. Cancelling restores a position
        // the delegator already held; it is not a new delegation. Gating it
        // would let the owner convert a cancellable request into a forced exit
        // by deactivating the representative mid cooldown.
        Representative storage r = _reps[d.repId];
        if (!r.exists) revert UnknownRepresentative(d.repId);

        _harvest(d);
        _accrueRepCommission(r);

        uint256 amount = d.pendingUnstake;
        d.pendingUnstake = 0;
        d.unstakeReadyAt = 0;
        totalPendingUnstake -= amount;

        if (d.amount == 0) {
            r.delegatorCount += 1;
            r.pendingDelegators -= 1;
        }
        d.amount += amount.toUint128();
        r.totalDelegated += amount;
        totalStaked += amount;

        _bookmark(d, r);
        emit UnstakeCancelled(msg.sender, d.repId, amount);
    }

    function withdrawUnstaked() external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        if (d.unstakeReadyAt == 0) revert NoPendingUnstake();
        if (block.timestamp < d.unstakeReadyAt) revert CooldownActive(d.unstakeReadyAt);

        uint256 amount = d.pendingUnstake;
        d.pendingUnstake = 0;
        d.unstakeReadyAt = 0;
        totalPendingUnstake -= amount;
        if (d.amount == 0) _reps[d.repId].pendingDelegators -= 1;

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
        _rewardsOwed = amount > _rewardsOwed ? 0 : _rewardsOwed - amount;

        hcow.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Anyone may trigger a payout, but it only ever goes to the
    ///         representative's registered payout address.
    function claimCommission(bytes32 repId) external nonReentrant {
        Representative storage r = _reps[repId];
        if (!r.exists) revert UnknownRepresentative(repId);

        _updateGlobal();
        _accrueRepCommission(r);

        uint256 amount = r.commissionAccrued;
        if (amount == 0) revert NothingToClaim();
        r.commissionAccrued = 0;
        _rewardsOwed = amount > _rewardsOwed ? 0 : _rewardsOwed - amount;

        hcow.safeTransfer(r.payout, amount);
        emit CommissionClaimed(repId, r.payout, amount);
    }

    // ------------------------------------------------------------------
    // rewards
    // ------------------------------------------------------------------

    /**
     * @notice Fund a reward period. The amount is released per second over
     *         `duration`, so every staked token earns for exactly the seconds
     *         it was staked. Each representative's commission comes off its
     *         delegators' share at the rate in force while it accrued.
     * @dev HCOW cannot be minted, so the funder must hold and approve the
     *      tokens. Nothing is created here. Whatever the running period has
     *      not released, plus anything that elapsed with nothing staked, rolls
     *      into the new rate: funding early stretches the budget rather than
     *      discarding it, and the new rate may never be slower than the one it
     *      replaces.
     * @param amount   HCOW to add to the stream.
     * @param duration Seconds the new period runs for.
     */
    function fundRewards(uint256 amount, uint64 duration) external nonReentrant {
        if (msg.sender != rewardFunder) revert NotFunder();
        if (duration > MAX_REWARD_DURATION) revert BadDuration(duration);

        // Advance first. Seconds that elapsed with nothing staked only become
        // visible in undistributed when some call runs the accumulator, and
        // opening a period on carried funds is exactly the state where nobody
        // has. Reading it before this ran rejected the call for having nothing
        // to carry, in the one case the path exists for.
        _updateGlobal();

        uint256 received;
        if (amount > 0) {
            uint256 before = hcow.balanceOf(address(this));
            hcow.safeTransferFrom(msg.sender, address(this), amount);
            received = hcow.balanceOf(address(this)) - before;
            if (received == 0) revert ZeroAmount();
        }

        // Whatever the running period has not released yet, plus anything that
        // elapsed while nothing was staked, rolls into the new one. Funding
        // early therefore stretches the budget rather than discarding it.
        uint256 leftover = block.timestamp < periodFinish
            ? (uint256(periodFinish) - block.timestamp) * rewardRate
            : 0;
        if (received == 0 && undistributed == 0) revert ZeroAmount();

        // The floor applies to a fresh period. A live one may be extended to
        // its own end date, which can be nearer than the floor.
        uint256 minDuration = block.timestamp < periodFinish
            ? uint256(periodFinish) - block.timestamp
            : MIN_REWARD_DURATION;
        if (duration < minDuration) revert BadDuration(duration);

        uint256 pool = received + leftover + undistributed;
        undistributed = 0;

        uint256 newRate = pool / duration;
        // A funding may never slow the stream already running. Without this a
        // single wei on a year long duration stretches the whole remaining
        // budget out behind it, and nobody but the funder can undo it. Nothing
        // would be destroyed, but delivery would be deferrable forever by a
        // role that is not the owner.
        if (block.timestamp < periodFinish) {
            // Neither the rate nor the end date may move backwards. Blocking
            // only the rate leaves the mirror image open: a single wei on the
            // shortest duration pulls the end date in and compresses the whole
            // remaining budget into it, which destroys exactly the time
            // weighting this design exists to create. A funding may add tokens
            // or add time. It may never redistribute what is already promised.
            uint256 minRate = leftover / (uint256(periodFinish) - block.timestamp);
            if (newRate < minRate) revert BadDuration(duration);
        }
        if (newRate == 0) revert BadDuration(duration);
        rewardRate = newRate;
        // The remainder of the division would otherwise be lost for good.
        undistributed = pool - rewardRate * duration;

        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp) + duration;
        totalRewardsFunded += received;

        emit RewardsFunded(received, rewardRate, duration);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function pendingRewardOf(address account) public view returns (uint256) {
        Delegation storage d = _delegations[account];
        if (d.amount == 0) return d.claimable;

        // Project the accumulator forward the same way _updateGlobal would.
        uint256 acc = accRewardPerShare;
        uint64 t = uint64(block.timestamp) < periodFinish
            ? uint64(block.timestamp)
            : periodFinish;
        if (t > lastUpdateTime && totalStaked >= MIN_STAKE_FOR_ACCRUAL) {
            acc += Math.mulDiv(uint256(t - lastUpdateTime) * rewardRate, ACC_PRECISION, totalStaked);
        }

        Representative storage r = _reps[d.repId];
        uint256 netAcc = r.accNetBase
            + ((acc - r.accNetAnchor) * (10_000 - r.commissionBps)) / 10_000;
        uint256 net = Math.mulDiv(uint256(d.amount), netAcc, ACC_PRECISION);
        return d.claimable + (net > d.rewardDebtNet ? net - d.rewardDebtNet : 0);
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

    /**
     * @dev Advance the global accumulator to now.
     *
     * Must run before anything that changes totalStaked, and before anything
     * that reads an account's accrual, or the seconds either side of the
     * change are priced at the wrong weight.
     */
    function _updateGlobal() private {
        uint64 t = uint64(block.timestamp) < periodFinish
            ? uint64(block.timestamp)
            : periodFinish;
        if (t <= lastUpdateTime) return;

        uint256 elapsed = uint256(t - lastUpdateTime);
        uint256 released = elapsed * rewardRate;
        if (released > 0) {
            uint256 inc = totalStaked >= MIN_STAKE_FOR_ACCRUAL
                ? Math.mulDiv(released, ACC_PRECISION, totalStaked)
                : 0;
            if (inc > 0) {
                accRewardPerShare += inc;
                // Reserve the whole window. Individual credits are differences
                // of two floors, so their sum can sit a wei above the exact
                // figure per delegator; reserving the exact figure instead
                // would let the reserve fall below what is claimable.
                _rewardsOwed += released;
            } else {
                // Either nothing is staked, or the window is too small to move
                // the accumulator. Carry it rather than stranding it or handing
                // the whole window to whoever stakes next, which would be the
                // lump sum problem again.
                undistributed += released;
            }
        }
        lastUpdateTime = t;
    }

    /// @dev The representative's net-of-commission accumulator. Exact without
    ///      touching storage on every rep, because the commission fraction is
    ///      constant between changes and the anchor records where it changed.
    function _netAcc(Representative storage r) private view returns (uint256) {
        return r.accNetBase
            + ((accRewardPerShare - r.accNetAnchor) * (10_000 - r.commissionBps)) / 10_000;
    }

    /// @dev Freeze the representative's net accumulator at the current
    ///      commission before that commission changes, so a change can never
    ///      reach backwards into rewards that already accrued.
    function _freezeCommission(Representative storage r) private {
        r.accNetBase = _netAcc(r);
        r.accNetAnchor = accRewardPerShare;
    }

    /**
     * @dev Fold commission earned since the last anchor into the
     *      representative's balance. Must run before any change to its
     *      delegated weight or its commission rate, because both are constant
     *      between calls and that is what makes the integral exact.
     */
    function _accrueRepCommission(Representative storage r) private {
        uint256 delta = accRewardPerShare - r.commAnchor;
        if (delta > 0 && r.totalDelegated > 0 && r.commissionBps > 0) {
            // Divided before the second multiply so the intermediate stays
            // far from the top of the word even in the degenerate case of a
            // one wei pool absorbing the whole supply.
            uint256 earned =
                Math.mulDiv(r.totalDelegated, delta, ACC_PRECISION) * r.commissionBps / 10_000;
            if (earned > 0) r.commissionAccrued += earned;
        }
        r.commAnchor = accRewardPerShare;
    }

    /**
     * @notice HCOW held to pay accrued delegator rewards and commission.
     *
     * Projected to this second. The stored figure only moves when someone
     * calls in, so a view that returned it directly would understate the
     * liability for as long as the contract sits idle, and would disagree with
     * pendingRewardOf.
     *
     * This is a reserve, not a sum. Each account's credit is the difference of
     * two independently floored figures, so adding up every pendingRewardOf
     * and commissionOf can land up to one wei per delegator above it. The
     * decrements on the claim paths are clamped so that can never revert a
     * claim, and solvency is maintained against the token balance rather than
     * against this counter.
     */
    function totalRewardsOwed() public view returns (uint256) {
        uint256 owed = _rewardsOwed;
        uint64 t = uint64(block.timestamp) < periodFinish
            ? uint64(block.timestamp)
            : periodFinish;
        if (t > lastUpdateTime && totalStaked >= MIN_STAKE_FOR_ACCRUAL) {
            uint256 released = uint256(t - lastUpdateTime) * rewardRate;
            // Mirror _updateGlobal exactly: a window too small to move the
            // accumulator is carried, not owed, and counting it here would
            // double it against undistributed.
            if (Math.mulDiv(released, ACC_PRECISION, totalStaked) > 0) owed += released;
        }
        return owed;
    }

    /// @notice Commission a representative could claim right now.
    function commissionOf(bytes32 id) external view returns (uint256) {
        Representative storage r = _reps[id];
        if (!r.exists) revert UnknownRepresentative(id);
        uint256 acc = accRewardPerShare;
        uint64 t = uint64(block.timestamp) < periodFinish
            ? uint64(block.timestamp)
            : periodFinish;
        if (t > lastUpdateTime && totalStaked >= MIN_STAKE_FOR_ACCRUAL) {
            acc += Math.mulDiv(uint256(t - lastUpdateTime) * rewardRate, ACC_PRECISION, totalStaked);
        }
        uint256 delta = acc - r.commAnchor;
        uint256 pending = (delta > 0 && r.totalDelegated > 0 && r.commissionBps > 0)
            ? Math.mulDiv(r.totalDelegated, delta, ACC_PRECISION) * r.commissionBps / 10_000
            : 0;
        return r.commissionAccrued + pending;
    }

    function _bookmark(Delegation storage d, Representative storage r) private {
        uint256 amt = uint256(d.amount);
        d.rewardDebtNet = Math.mulDiv(amt, _netAcc(r), ACC_PRECISION);
    }

    /**
     * @dev Fold accrual into stored balances. Commission is the difference
     *      between what the stream produced for the position and what the
     *      representative's net accumulator says the delegator keeps, so it is
     *      taken at the rate that was in force while it accrued.
     */
    function _harvest(Delegation storage d) private {
        _updateGlobal();
        if (d.amount > 0) {
            Representative storage r = _reps[d.repId];
            uint256 amt = uint256(d.amount);
            uint256 net = Math.mulDiv(amt, _netAcc(r), ACC_PRECISION);
            uint256 netDelta = net > d.rewardDebtNet ? net - d.rewardDebtNet : 0;
            if (netDelta > 0) {
                d.claimable += netDelta;
                r.lifetimeRewards += netDelta;
            }
            // Commission is deliberately not taken here. It is an aggregate
            // over the representative's whole weight, folded in by
            // _accrueRepCommission, so a representative is paid without having
            // to wait for every delegator to touch their position.
            d.rewardDebtNet = net;
        } else {
            d.rewardDebtNet = 0;
        }
    }
}
