// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/**
 * @title HCOWProfitShare
 * @notice Bonded Deposit. Participants bond HCOW, the bonded pool is consumed
 *         in proportion to ecosystem usage, and net profit is distributed in
 *         USDT each epoch.
 *
 * WHAT THE CHAIN ENFORCES
 *   - The 50 / 25 / 25 split is computed here. It is never passed in.
 *   - The opex cap is checked here. Operating costs above OPEX_CAP_BPS of net
 *     revenue are rejected, so the cap cannot be quietly exceeded.
 *   - Rule 5, the per settlement deduction cap. No single settlement can
 *     consume more than MAX_DEDUCT_BPS of the bonded pool, so the worst case
 *     for a participant is bounded by the code and not by trust.
 *   - Rule 4, no distribution no deduction. If an epoch produces zero
 *     distributable profit, bonded principal cannot be deducted for it. The
 *     spec says to enforce this at the contract level, so it is enforced here
 *     and not in the UI.
 *   - The USDT is pulled in during settlement. A published distribution number
 *     that was never funded will revert, so the figures on the dashboard and
 *     the money that moved are the same figures.
 *   - Epochs are strictly sequential and settle exactly once. There is no
 *     function that edits a settled epoch.
 *
 * WHAT THE CHAIN CANNOT ENFORCE
 *   Gross revenue and the cost lines are produced off chain. Apple and Google
 *   settle by bank transfer; no contract can audit that. What this contract
 *   does is make the published numbers immutable and arithmetically
 *   consistent, and require that the profit actually arrives. The honest claim
 *   is "the published waterfall cannot be edited after the fact and the money
 *   moved as stated", not "the revenue is proven".
 *
 * ACCOUNTING
 *   Bonded balances are held as shares. Deduction lowers the pool's HCOW
 *   without touching a single user record, so every participant shrinks by the
 *   same proportion in one operation. USDT uses the accumulator pattern, so a
 *   distribution is O(1) regardless of how many participants there are.
 */
contract HCOWProfitShare is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // constants
    // ------------------------------------------------------------------

    /// @notice Deductible opex ceiling, as a share of net revenue. 40%.
    uint16 public constant OPEX_CAP_BPS = 4000;

    uint16 public constant PARTICIPANT_BPS = 5000; // 50%
    uint16 public constant GAME_COMPANY_BPS = 2500; // 25%
    uint16 public constant TEAM_BPS = 2500; // 25%

    /// @notice Bonded principal deductible in a single settlement, as a share
    ///         of the pool. 2%. This is a hard ceiling, not a target. The
    ///         settler computes the deduction off chain from the value rule
    ///         published in the protocol documents, and this cap bounds the
    ///         worst case regardless of what that computation returns.
    uint16 public constant MAX_DEDUCT_BPS = 200;

    uint256 private constant ACC_PRECISION = 1e18;

    /// @notice Wait between requesting an unbond and being able to withdraw.
    uint256 public constant UNBOND_COOLDOWN = 7 days;

    // ------------------------------------------------------------------
    // storage
    // ------------------------------------------------------------------

    IERC20 public immutable hcow;
    IERC20 public immutable usdt;

    address public owner;
    address public settler;

    /// @notice Recipients of the two 25% shares. They may be the same address.
    address public gameCompany;
    address public team;

    struct Account {
        uint128 shares;          // claim on the bonded pool
        uint128 pendingUnbond;   // HCOW, fixed at request time, no longer earning
        uint64  unbondReadyAt;   // 0 when there is no pending unbond
        uint256 rewardDebt;      // USDT accumulator bookmark
        uint256 claimableUsdt;
        uint256 deductDebt;      // deduction accumulator bookmark
        uint256 settledDeducted; // deduction already folded into the total below
        uint256 lifetimeClaimedUsdt;
    }

    mapping(address => Account) private _accounts;

    /// @notice HCOW currently bonded and earning. Falls as usage is deducted.
    uint256 public totalBondedHcow;
    /// @notice Total shares outstanding against totalBondedHcow.
    uint256 public totalShares;
    /// @notice HCOW reserved for pending unbonds. Never deducted, never earning.
    uint256 public totalPendingUnbond;

    uint256 public accUsdtPerShare;

    /**
     * @notice Deduction accumulator, the mirror of accUsdtPerShare.
     *
     * Deduction is applied to the pool in one operation by shrinking
     * totalBondedHcow, which is why it costs the same gas for one participant
     * or ten thousand. That is correct but it leaves no per-account record
     * behind, so this accumulator reconstructs one: each account's share of
     * every deduction, without a per-account write at settlement time.
     */
    uint256 public accDeductedPerShare;

    /// @notice Accounts currently holding shares. A pending unbond is not counted.
    uint256 public participantCount;
    uint256 public totalUsdtDistributed;
    uint256 public totalHcowDeducted;

    /// @notice Next epoch expected. Also the number of settled epochs.
    uint64 public nextEpoch;

    struct Settlement {
        uint128 grossReceivedUsdt;
        uint128 directCostsUsdt;
        uint128 operatingCostsUsdt;
        uint128 distributableProfitUsdt;
        uint128 participantsUsdt;
        uint128 hcowDeducted;
        uint128 snapshotBondedHcow;
        uint64  settledAt;
    }

    mapping(uint64 => Settlement) private _settlements;

    // ------------------------------------------------------------------
    // events
    // ------------------------------------------------------------------

    event Bonded(address indexed account, uint256 hcowAmount, uint256 sharesMinted);
    event UnbondRequested(address indexed account, uint256 hcowAmount, uint64 readyAt);
    event UnbondCancelled(address indexed account, uint256 hcowAmount, uint256 sharesMinted);
    event Unbonded(address indexed account, uint256 hcowAmount);
    event UsdtClaimed(address indexed account, uint256 amount);

    /**
     * @dev The two 25% legs are not repeated here. They are exactly a quarter
     *      of distributableProfitUsdt each, and the actual movement shows up as
     *      ERC20 Transfer events to gameCompany and team in the same
     *      transaction, which is the stronger record anyway.
     */
    event EpochSettled(
        uint64 indexed epoch,
        uint256 grossReceivedUsdt,
        uint256 directCostsUsdt,
        uint256 netRevenueUsdt,
        uint256 operatingCostsUsdt,
        uint256 distributableProfitUsdt,
        uint256 participantsUsdt,
        uint256 hcowDeducted,
        uint256 snapshotBondedHcow
    );

    event SettlerChanged(address indexed account);
    event RecipientsChanged(address indexed gameCompany, address indexed team);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ------------------------------------------------------------------
    // errors
    // ------------------------------------------------------------------

    error NotOwner();
    error NotSettler();
    error ZeroAddress();
    error ZeroAmount();
    error WrongEpoch(uint64 expected, uint64 given);
    error CostsExceedRevenue();
    error OpexAboveCap(uint256 submitted, uint256 cap);
    error DeductionWithoutDistribution();
    error DeductionAboveCap(uint256 requested, uint256 cap);
    error NothingBonded();
    error InsufficientBonded(uint256 requested, uint256 available);
    error UnbondAlreadyPending();
    error NoPendingUnbond();
    error CooldownActive(uint64 readyAt);
    error NothingToClaim();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySettler() {
        if (msg.sender != settler) revert NotSettler();
        _;
    }

    constructor(
        address hcowToken,
        address usdtToken,
        address initialOwner,
        address initialSettler,
        address gameCompany_,
        address team_
    ) {
        if (
            hcowToken == address(0) || usdtToken == address(0) ||
            initialOwner == address(0) || initialSettler == address(0) ||
            gameCompany_ == address(0) || team_ == address(0)
        ) revert ZeroAddress();

        hcow = IERC20(hcowToken);
        usdt = IERC20(usdtToken);
        owner = initialOwner;
        settler = initialSettler;
        gameCompany = gameCompany_;
        team = team_;

        emit OwnershipTransferred(address(0), initialOwner);
        emit SettlerChanged(initialSettler);
        emit RecipientsChanged(gameCompany_, team_);
    }

    // ------------------------------------------------------------------
    // participant actions
    // ------------------------------------------------------------------

    /// @notice Bond HCOW into the shared pool.
    function bond(uint256 hcowAmount) external nonReentrant {
        if (hcowAmount == 0) revert ZeroAmount();

        Account storage a = _accounts[msg.sender];
        _settle(a);

        // Measure what actually arrived. Never trust the argument.
        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), hcowAmount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        uint256 minted = totalShares == 0 || totalBondedHcow == 0
            ? received
            : (received * totalShares) / totalBondedHcow;
        if (minted == 0) revert ZeroAmount();

        if (a.shares == 0) participantCount += 1;
        a.shares += uint128(minted);
        totalShares += minted;
        totalBondedHcow += received;

        _bookmark(a);
        emit Bonded(msg.sender, received, minted);
    }

    /**
     * @notice Start withdrawing part or all of a bonded position.
     * @dev The amount is fixed in HCOW at request time. From this moment it
     *      stops earning and stops being deducted. A participant on the way
     *      out should not keep absorbing usage.
     */
    function requestUnbond(uint256 hcowAmount) external nonReentrant {
        if (hcowAmount == 0) revert ZeroAmount();
        Account storage a = _accounts[msg.sender];
        if (a.unbondReadyAt != 0) revert UnbondAlreadyPending();

        _settle(a);

        uint256 owned = bondedOf(msg.sender);
        if (owned == 0) revert NothingBonded();
        if (hcowAmount > owned) revert InsufficientBonded(hcowAmount, owned);

        // Burn shares proportional to the HCOW being pulled out.
        uint256 sharesToBurn = (hcowAmount * uint256(a.shares)) / owned;
        if (sharesToBurn == 0) revert ZeroAmount();

        a.shares -= uint128(sharesToBurn);
        if (a.shares == 0) participantCount -= 1;
        totalShares -= sharesToBurn;
        totalBondedHcow -= hcowAmount;

        a.pendingUnbond = uint128(hcowAmount);
        a.unbondReadyAt = uint64(block.timestamp + UNBOND_COOLDOWN);
        totalPendingUnbond += hcowAmount;

        _bookmark(a);
        emit UnbondRequested(msg.sender, hcowAmount, a.unbondReadyAt);
    }

    /// @notice Put a pending unbond back to work at the current share price.
    function cancelUnbond() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        if (a.unbondReadyAt == 0) revert NoPendingUnbond();

        _settle(a);

        uint256 amount = a.pendingUnbond;
        a.pendingUnbond = 0;
        a.unbondReadyAt = 0;
        totalPendingUnbond -= amount;

        uint256 minted = totalShares == 0 || totalBondedHcow == 0
            ? amount
            : (amount * totalShares) / totalBondedHcow;
        if (minted == 0) revert ZeroAmount();

        if (a.shares == 0) participantCount += 1;
        a.shares += uint128(minted);
        totalShares += minted;
        totalBondedHcow += amount;

        _bookmark(a);
        emit UnbondCancelled(msg.sender, amount, minted);
    }

    /// @notice Take out a pending unbond once the cooldown has passed.
    function withdrawUnbonded() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        if (a.unbondReadyAt == 0) revert NoPendingUnbond();
        if (block.timestamp < a.unbondReadyAt) revert CooldownActive(a.unbondReadyAt);

        uint256 amount = a.pendingUnbond;
        a.pendingUnbond = 0;
        a.unbondReadyAt = 0;
        totalPendingUnbond -= amount;

        hcow.safeTransfer(msg.sender, amount);
        emit Unbonded(msg.sender, amount);
    }

    /// @notice Take the USDT accumulated across settled epochs.
    function claimUsdt() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        _settle(a);

        uint256 amount = a.claimableUsdt;
        if (amount == 0) revert NothingToClaim();
        a.claimableUsdt = 0;
        a.lifetimeClaimedUsdt += amount;

        usdt.safeTransfer(msg.sender, amount);
        emit UsdtClaimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // settlement
    // ------------------------------------------------------------------

    /**
     * @notice Settle one epoch and distribute its profit.
     *
     * The settler must have approved `distributableProfitUsdt` of USDT to this
     * contract. It is pulled in here, so a number that was published but never
     * funded cannot be settled.
     *
     * @param epoch                Must equal nextEpoch.
     * @param grossReceivedUsdt    Money actually received into the vault.
     * @param directCostsUsdt      Platform fees, processing, FX, transaction tax.
     * @param operatingCostsUsdt   The capped, closed-list operating costs.
     * @param hcowToDeduct         Bonded principal consumed by usage this epoch.
     */
    function settleEpoch(
        uint64 epoch,
        uint256 grossReceivedUsdt,
        uint256 directCostsUsdt,
        uint256 operatingCostsUsdt,
        uint256 hcowToDeduct
    ) external onlySettler nonReentrant {
        if (epoch != nextEpoch) revert WrongEpoch(nextEpoch, epoch);
        if (directCostsUsdt > grossReceivedUsdt) revert CostsExceedRevenue();

        uint256 netRevenue = grossReceivedUsdt - directCostsUsdt;

        // Rule 1. The cap is not advisory. Anything above it must be absorbed
        // by the studio and team shares before it reaches this function.
        uint256 cap = (netRevenue * OPEX_CAP_BPS) / 10_000;
        if (operatingCostsUsdt > cap) revert OpexAboveCap(operatingCostsUsdt, cap);

        uint256 profit = netRevenue - operatingCostsUsdt;

        // Rule 4. No distribution, no deduction.
        if (profit == 0 && hcowToDeduct != 0) revert DeductionWithoutDistribution();
        // Rule 5. The deduction is capped per settlement. Even a compromised
        // or mistaken settler cannot consume more than MAX_DEDUCT_BPS of the
        // bonded pool in one epoch.
        uint256 deductCap = (totalBondedHcow * MAX_DEDUCT_BPS) / 10_000;
        if (hcowToDeduct > deductCap) {
            revert DeductionAboveCap(hcowToDeduct, deductCap);
        }

        uint256 participants = (profit * PARTICIPANT_BPS) / 10_000;
        uint256 snapshot = totalBondedHcow;

        if (profit > 0) {
            usdt.safeTransferFrom(msg.sender, address(this), profit);
            uint256 toGameCompany = (profit * GAME_COMPANY_BPS) / 10_000;
            // Remainder to the team so rounding never strands dust here.
            uint256 toTeam = profit - participants - toGameCompany;
            if (toGameCompany > 0) usdt.safeTransfer(gameCompany, toGameCompany);
            if (toTeam > 0) usdt.safeTransfer(team, toTeam);
        }

        if (participants > 0) {
            if (totalShares == 0) {
                // Nobody is bonded. Send the participant share back rather
                // than stranding it in a pool with no claimants.
                usdt.safeTransfer(msg.sender, participants);
                participants = 0;
            } else {
                accUsdtPerShare += (participants * ACC_PRECISION) / totalShares;
                totalUsdtDistributed += participants;
            }
        }

        if (hcowToDeduct > 0) {
            // totalShares cannot be zero here: hcowToDeduct is bounded by
            // totalBondedHcow above, and an empty pool has no bonded HCOW.
            accDeductedPerShare += (hcowToDeduct * ACC_PRECISION) / totalShares;
            totalBondedHcow -= hcowToDeduct;
            totalHcowDeducted += hcowToDeduct;
            IBurnable(address(hcow)).burn(hcowToDeduct);
        }

        _settlements[epoch] = Settlement({
            grossReceivedUsdt: uint128(grossReceivedUsdt),
            directCostsUsdt: uint128(directCostsUsdt),
            operatingCostsUsdt: uint128(operatingCostsUsdt),
            distributableProfitUsdt: uint128(profit),
            participantsUsdt: uint128(participants),
            hcowDeducted: uint128(hcowToDeduct),
            snapshotBondedHcow: uint128(snapshot),
            settledAt: uint64(block.timestamp)
        });

        nextEpoch = epoch + 1;

        emit EpochSettled(
            epoch, grossReceivedUsdt, directCostsUsdt, netRevenue,
            operatingCostsUsdt, profit, participants, hcowToDeduct, snapshot
        );
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    /// @notice HCOW currently backing an account's shares.
    function bondedOf(address account) public view returns (uint256) {
        uint256 s = _accounts[account].shares;
        if (s == 0 || totalShares == 0) return 0;
        return (s * totalBondedHcow) / totalShares;
    }

    /// @notice USDT an account could claim right now.
    function claimableOf(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        uint256 accrued = (uint256(a.shares) * accUsdtPerShare) / ACC_PRECISION;
        return a.claimableUsdt + (accrued > a.rewardDebt ? accrued - a.rewardDebt : 0);
    }

    function accountOf(address account)
        external
        view
        returns (uint256 bondedHcow, uint256 shares, uint256 pendingUnbond, uint64 unbondReadyAt)
    {
        Account storage a = _accounts[account];
        return (bondedOf(account), a.shares, a.pendingUnbond, a.unbondReadyAt);
    }

    /**
     * @notice Lifetime totals for an account.
     * @dev deductedHcow includes deduction that has accrued but has not yet
     *      been folded in by a state-changing call, so it is correct between
     *      settlements without anyone having to poke the contract.
     */
    function lifetimeOf(address account)
        external
        view
        returns (uint256 deductedHcow, uint256 claimedUsdt)
    {
        Account storage a = _accounts[account];
        uint256 s = uint256(a.shares);
        deductedHcow = a.settledDeducted;
        if (s > 0) {
            uint256 accrued = (s * accDeductedPerShare) / ACC_PRECISION;
            if (accrued > a.deductDebt) deductedHcow += accrued - a.deductDebt;
        }
        claimedUsdt = a.lifetimeClaimedUsdt;
    }

    function getSettlement(uint64 epoch) external view returns (Settlement memory) {
        return _settlements[epoch];
    }

    /// @notice Maximum opex that would be accepted for a given revenue pair.
    function opexCapFor(uint256 grossReceivedUsdt, uint256 directCostsUsdt)
        external
        pure
        returns (uint256)
    {
        if (directCostsUsdt > grossReceivedUsdt) return 0;
        return ((grossReceivedUsdt - directCostsUsdt) * OPEX_CAP_BPS) / 10_000;
    }

    // ------------------------------------------------------------------
    // administration. none of it can alter a settled epoch.
    // ------------------------------------------------------------------

    function setSettler(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        settler = account;
        emit SettlerChanged(account);
    }

    /// @dev The two 25% recipients. They are allowed to be the same address,
    ///      and whichever they are, they are visible on chain.
    function setRecipients(address gameCompany_, address team_) external onlyOwner {
        if (gameCompany_ == address(0) || team_ == address(0)) revert ZeroAddress();
        gameCompany = gameCompany_;
        team = team_;
        emit RecipientsChanged(gameCompany_, team_);
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
     * Fold everything that accrued at the account's current share count into
     * stored balances, then re-bookmark both accumulators. Must be called
     * before any change to a.shares, and the bookmarks re-set after.
     */
    function _settle(Account storage a) private {
        uint256 s = uint256(a.shares);
        if (s > 0) {
            uint256 usdtAccrued = (s * accUsdtPerShare) / ACC_PRECISION;
            if (usdtAccrued > a.rewardDebt) {
                a.claimableUsdt += usdtAccrued - a.rewardDebt;
            }
            uint256 deducted = (s * accDeductedPerShare) / ACC_PRECISION;
            if (deducted > a.deductDebt) {
                a.settledDeducted += deducted - a.deductDebt;
            }
        }
        _bookmark(a);
    }

    function _bookmark(Account storage a) private {
        uint256 s = uint256(a.shares);
        a.rewardDebt = (s * accUsdtPerShare) / ACC_PRECISION;
        a.deductDebt = (s * accDeductedPerShare) / ACC_PRECISION;
    }
}
