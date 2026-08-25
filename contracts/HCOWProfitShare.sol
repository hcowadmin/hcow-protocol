// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
 *   - Rule 5, the deduction rate limit. The settler no longer passes an HCOW
 *     amount. It passes a rate in parts per million, capped at MAX_DEDUCT_PPM,
 *     and the contract computes the amount from its own pool figure. With
 *     MIN_EPOCH_INTERVAL between settlements the worst case is 2% per week,
 *     and a position that requests an unbond is charged for exactly one
 *     settlement, so reacting costs at most 2% of principal. Over any thirty
 *     days MAX_DECAY_PER_WINDOW_PPM binds instead. Those are bounds the code
 *     enforces, not promises.
 *   - Rule 6, a deduction requires a real distribution. The participant leg of
 *     the epoch must be non-zero. An epoch that pays participants nothing
 *     cannot consume their principal, however it is arithmetically dressed up.
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
    using SafeCast for uint256;

    // ------------------------------------------------------------------
    // constants
    // ------------------------------------------------------------------

    /// @notice Deductible opex ceiling, as a share of net revenue. 40%.
    uint16 public constant OPEX_CAP_BPS = 4000;

    uint16 public constant PARTICIPANT_BPS = 5000; // 50%
    uint16 public constant GAME_COMPANY_BPS = 2500; // 25%
    uint16 public constant TEAM_BPS = 2500; // 25%

    /// @notice Deduction rate ceiling for one settlement, in parts per
    ///         million of the bonded pool. 20,000 ppm is 2%. Parts per million
    ///         rather than basis points so that a small, honest deduction does
    ///         not truncate to nothing on a large pool.
    uint32 public constant MAX_DEDUCT_PPM = 20_000;

    uint256 private constant PPM_DENOM = 1_000_000;

    /// @notice Precision of poolIndex. Deliberately finer than ACC_PRECISION:
    ///         the index is a running product, so its error compounds.
    uint256 private constant RAY = 1e27;

    /**
     * @notice Where consumed principal goes.
     *
     * Deliberately a transfer to the standard burn address rather than a call
     * to the token's own burn function. An exit must never depend on an
     * external function that could be paused, role gated, or simply absent
     * from the deployed token: HCOW is not in this repository, and a burn that
     * reverts would lock every pending position permanently. A transfer works
     * against any ERC20 and removes the supply just as verifiably.
     */
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice A settlement must distribute at least this much to participants
    ///         before it may consume principal. One USDT. This is a sanity
    ///         floor against an epoch that pays a rounding error and burns two
    ///         percent of the pool, not an economic bound. The economic bound
    ///         is the rate limit below.
    uint256 public constant MIN_PARTICIPANT_USDT = 1e18;

    /**
     * @notice Minimum wait between two settlements.
     *
     * Arrivals are quarantined for the epoch they land in, and an epoch that
     * distributes nothing costs the settler nothing to produce. Without a
     * floor on epoch length, two settlements in adjacent blocks release a
     * position from quarantine for free and hand it the whole of the next
     * distribution, which is the defect the quarantine exists to prevent.
     * A floor makes an epoch a period of time rather than a call.
     *
     * The floor is the unbond cooldown for a reason. Quarantine ends at the
     * next settlement, so a shorter floor lets an arrival buy eligibility for
     * a large distribution with a day of exposure. Matching the two means
     * becoming eligible costs the same real time as leaving does.
     */
    uint256 public constant MIN_EPOCH_INTERVAL = 7 days;

    /**
     * @notice Ceiling on how much of the pool may be consumed within one
     *         window, on top of the per settlement cap.
     *
     * A per settlement cap bounds a mistake. It does not bound a campaign:
     * two percent a week, repeated, still reaches the whole pool. The
     * published usage rule decays roughly half a percent a month, so three
     * percent leaves six times the headroom an honest settler needs and puts a
     * hard floor under the worst case a compromised one can reach.
     *
     * The window is fixed, not sliding, so two adjacent windows can pack their
     * allowances back to back and a rolling thirty days can therefore reach
     * close to twice this figure. That is the honest bound; it is stated here
     * rather than rounded down in the documentation.
     *
     * It bounds what settlements burn. HCOW forfeited by a position leaving
     * around a settlement is burned outside this meter, deliberately: metering
     * it would let a large holder exhaust the window at will and veto every
     * deduction for thirty days.
     */
    uint32 public constant MAX_DECAY_PER_WINDOW_PPM = 30_000;
    uint256 public constant DECAY_WINDOW = 30 days;

    /// @notice Accumulator precision. Finer than the token's own decimals so
    ///         a small distribution over a large pool is not floored away into
    ///         value nobody can claim. Every product it appears in uses mulDiv,
    ///         so the extra orders cost no headroom.
    uint256 private constant ACC_PRECISION = 1e24;

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
        uint256 unbondIndex;     // poolIndex at the moment the unbond was requested
        uint64  unbondEpoch;     // nextEpoch at that moment, the walk's start
        uint128 newShares;       // bonded this epoch, principal already, not yet earning
        uint64  newSharesEpoch;  // the epoch those shares were bonded in
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
     * @notice Shares bonded during the epoch now being settled.
     *
     * They are principal from the moment they are minted, so they count in
     * totalShares, back bondedOf and absorb deduction. They do not earn the
     * epoch they arrived in. Without this a holder can bond immediately before
     * a settlement, take a full pro rata cut of a quarter's profit for one
     * block of exposure, and unbond. Settlement parameters are visible in the
     * mempool, so the payoff is known before the position is even opened.
     */
    uint256 public totalNewShares;

    /// @notice accUsdtPerShare immediately after each settled epoch. A
    ///         position promoted out of totalNewShares is credited from the
    ///         value recorded here, so it earns every epoch after the one it
    ///         joined even if nobody touches the account in between.
    mapping(uint64 => uint256) public accAtEpoch;

    /// @notice Timestamp of the last settlement.
    uint64 public lastSettledAt;

    /**
     * @notice When the current decay window opened, and how much HCOW has been
     *         consumed inside it.
     *
     * Metered in tokens rather than as a movement in poolIndex, because a rate
     * says nothing about how much was actually destroyed: with most of the
     * pool sitting in pending unbonds, two settlements at the cap burn a
     * rounding error and would still exhaust a ceiling expressed as a rate.
     *
     * The ceiling is computed from the live bonded pool at every settlement,
     * never from a figure snapshotted when the window opened. A snapshot stops
     * being true the moment it is written: capital can be parked in the pool
     * to inflate it and withdrawn a block later, and a pool that grows after
     * the snapshot is held to an allowance sized for a pool that no longer
     * exists. Reading it live also makes the ceiling and the deduction scale
     * together, so shrinking the pool in front of a settlement cannot
     * manufacture a veto.
     */
    uint64 public decayWindowAt;
    uint256 public decayWindowBurned;

    /// @notice poolIndex immediately after each settled epoch. A pending
    ///         unbond is priced against the first of these that follows it.
    mapping(uint64 => uint256) public poolIndexAtEpoch;

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

    /**
     * @notice Cumulative pool decay factor, 1e18 at genesis, falling with every
     *         deduction. A pending unbond records the value at request time, so
     *         cancelling one settles the deductions it sat out. Without this a
     *         participant could step out before a settlement and step back in
     *         after it, and never pay for usage at all.
     */
    uint256 public poolIndex = RAY;

    /// @notice Accounts currently holding shares. A pending unbond is not counted.
    uint256 public participantCount;
    uint256 public totalUsdtDistributed;

    /// @notice HCOW burned by settlements. Equals the sum of every settled
    ///         epoch's hcowDeducted, and nothing else, so the two reconcile.
    uint256 public totalHcowDeducted;

    /// @notice HCOW burned when a pending unbond settled the deductions it sat
    ///         through. Counted apart from totalHcowDeducted so that neither
    ///         figure has to be explained twice.
    uint256 public totalHcowForfeited;

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
    error DeductionRateAboveCap(uint32 requested, uint32 cap);
    error EpochTooSoon(uint64 readyAt);
    error DecayWindowExhausted(uint256 windowCap, uint256 wouldBe);
    error ProfitNotFunded(uint256 expected, uint256 arrived);
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
        a.shares += minted.toUint128();
        totalShares += minted;
        totalBondedHcow += received;
        _markNew(a, minted);

        _bookmark(a);
        emit Bonded(msg.sender, received, minted);
    }

    /**
     * @notice Start withdrawing part or all of a bonded position.
     * @dev The amount is fixed in HCOW at request time and stops earning from
     *      this moment. It does not stop being deducted outright: the first
     *      settlement after the request is charged, and exactly that one,
     *      whichever door the position later leaves by. Exempting it entirely
     *      is what used to make the deduction optional for anyone watching the
     *      mempool; charging every later settlement instead billed a holder
     *      who was merely slow to press withdraw, without bound.
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

        // Take it out of this epoch's arrivals first. They are the shares
        // that are not earning yet, so removing them costs the holder nothing
        // they had, and it keeps the account and the global counter in step.
        uint256 fromNew = sharesToBurn > a.newShares ? a.newShares : sharesToBurn;
        if (fromNew > 0) {
            a.newShares -= fromNew.toUint128();
            totalNewShares -= fromNew;
        }
        a.shares -= sharesToBurn.toUint128();
        if (a.shares == 0) participantCount -= 1;
        totalShares -= sharesToBurn;
        totalBondedHcow -= hcowAmount;

        a.pendingUnbond = hcowAmount.toUint128();
        a.unbondReadyAt = uint64(block.timestamp + UNBOND_COOLDOWN);
        a.unbondIndex = poolIndex;
        a.unbondEpoch = nextEpoch;
        totalPendingUnbond += hcowAmount;

        _bookmark(a);
        emit UnbondRequested(msg.sender, hcowAmount, a.unbondReadyAt);
    }

    /**
     * @notice Put a pending unbond back to work at the current share price.
     * @dev Rejoining is not free. The amount is scaled by the pool decay that
     *      happened while it sat pending, and the difference is burned. A
     *      participant who genuinely leaves pays nothing; a participant who
     *      steps out around a settlement and back in afterwards pays exactly
     *      what staying would have cost. Without this the deduction is
     *      optional for anyone watching the mempool.
     */
    function cancelUnbond() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        if (a.unbondReadyAt == 0) revert NoPendingUnbond();

        _settle(a);

        uint256 amount = a.pendingUnbond;
        uint256 startIndex = a.unbondIndex;
        uint256 endIndex = _chargeIndex(a);
        a.pendingUnbond = 0;
        a.unbondReadyAt = 0;
        a.unbondIndex = 0;
        a.unbondEpoch = 0;
        totalPendingUnbond -= amount;

        uint256 restored = startIndex == 0
            ? amount
            : Math.mulDiv(amount, endIndex, startIndex);
        if (restored > amount) restored = amount;
        uint256 forfeited = amount - restored;
        if (restored == 0) revert ZeroAmount();

        uint256 minted = totalShares == 0 || totalBondedHcow == 0
            ? restored
            : (restored * totalShares) / totalBondedHcow;
        if (minted == 0) revert ZeroAmount();

        if (a.shares == 0) participantCount += 1;
        a.shares += minted.toUint128();
        totalShares += minted;
        totalBondedHcow += restored;
        _markNew(a, minted);

        _bookmark(a);

        if (forfeited > 0) {
            a.settledDeducted += forfeited;
            totalHcowForfeited += forfeited;
            hcow.safeTransfer(BURN_ADDRESS, forfeited);
        }

        emit UnbondCancelled(msg.sender, restored, minted);
    }

    /**
     * @notice Take out a pending unbond once the cooldown has passed.
     * @dev Priced exactly like cancelUnbond. Requesting an unbond is not a way
     *      to sit out a settlement: whichever door the position leaves by, it
     *      pays for the deductions it was present for. Charging only the
     *      cancel path would simply move the dodge to this one.
     */
    function withdrawUnbonded() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        if (a.unbondReadyAt == 0) revert NoPendingUnbond();
        if (block.timestamp < a.unbondReadyAt) revert CooldownActive(a.unbondReadyAt);

        uint256 amount = a.pendingUnbond;
        uint256 startIndex = a.unbondIndex;
        uint256 endIndex = _chargeIndex(a);
        a.pendingUnbond = 0;
        a.unbondReadyAt = 0;
        a.unbondIndex = 0;
        a.unbondEpoch = 0;
        totalPendingUnbond -= amount;

        uint256 payout = startIndex == 0
            ? amount
            : Math.mulDiv(amount, endIndex, startIndex);
        if (payout > amount) payout = amount;
        uint256 forfeited = amount - payout;

        if (forfeited > 0) {
            a.settledDeducted += forfeited;
            totalHcowForfeited += forfeited;
            hcow.safeTransfer(BURN_ADDRESS, forfeited);
        }
        if (payout > 0) hcow.safeTransfer(msg.sender, payout);
        emit Unbonded(msg.sender, payout);
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
     * @param deductPpm            Share of the bonded pool consumed by usage
     *                             this epoch, in parts per million. The HCOW
     *                             amount is computed here, never passed in.
     */
    function settleEpoch(
        uint64 epoch,
        uint256 grossReceivedUsdt,
        uint256 directCostsUsdt,
        uint256 operatingCostsUsdt,
        uint32 deductPpm
    ) external onlySettler nonReentrant {
        if (epoch != nextEpoch) revert WrongEpoch(nextEpoch, epoch);
        if (lastSettledAt != 0) {
            uint64 openAt = lastSettledAt + uint64(MIN_EPOCH_INTERVAL);
            if (block.timestamp < openAt) revert EpochTooSoon(openAt);
        }
        if (directCostsUsdt > grossReceivedUsdt) revert CostsExceedRevenue();

        uint256 netRevenue = grossReceivedUsdt - directCostsUsdt;

        // Rule 1. The cap is not advisory. Anything above it must be absorbed
        // by the studio and team shares before it reaches this function.
        uint256 cap = (netRevenue * OPEX_CAP_BPS) / 10_000;
        if (operatingCostsUsdt > cap) revert OpexAboveCap(operatingCostsUsdt, cap);

        uint256 profit = netRevenue - operatingCostsUsdt;
        uint256 participants = (profit * PARTICIPANT_BPS) / 10_000;
        uint256 eligibleShares = totalShares - totalNewShares;

        // Rule 5. The rate is capped, and two deductions cannot be stacked
        // inside the cooldown. Together these bound the worst case at 2% a day.
        if (deductPpm > MAX_DEDUCT_PPM) {
            revert DeductionRateAboveCap(deductPpm, MAX_DEDUCT_PPM);
        }
        if (deductPpm != 0) {
            // Rule 4 and Rule 6. Principal is only consumed by an epoch that
            // actually pays participants, and the test is on what reaches
            // them, not on what was computed. One wei of profit rounds the
            // participant leg to zero, and with nobody eligible the leg is
            // returned to the settler; burning principal against either is the
            // same defect wearing different arithmetic.
            // Nobody eligible means the participant leg is returned below, so
            // there is nothing to charge and nothing to charge it against. The
            // deduction is dropped rather than the settlement refused: a single
            // dominant holder could otherwise veto every settlement by
            // front running it with an unbond request.
            if (eligibleShares != 0 && participants < MIN_PARTICIPANT_USDT) {
                revert DeductionWithoutDistribution();
            }
        }

        // The settler states a rate. The contract owns the arithmetic, so a
        // participant cannot invalidate a signed settlement by shrinking the
        // pool in front of it, and the settler cannot overstate the amount.
        uint256 hcowToDeduct = (eligibleShares == 0 || deductPpm == 0)
            ? 0
            : (totalBondedHcow * deductPpm) / PPM_DENOM;

        uint256 snapshot = totalBondedHcow;

        if (profit > 0) {
            // Measure what arrived, exactly as bond does for HCOW. Paying the
            // two fixed legs out of a figure that was requested rather than
            // received would take any shortfall out of the participant
            // reserve, and the contract would be quietly insolvent.
            uint256 beforeUsdt = usdt.balanceOf(address(this));
            usdt.safeTransferFrom(msg.sender, address(this), profit);
            uint256 arrived = usdt.balanceOf(address(this)) - beforeUsdt;
            if (arrived != profit) revert ProfitNotFunded(profit, arrived);
            uint256 toGameCompany = (profit * GAME_COMPANY_BPS) / 10_000;
            // Remainder to the team so rounding never strands dust here.
            uint256 toTeam = profit - participants - toGameCompany;
            if (toGameCompany > 0) usdt.safeTransfer(gameCompany, toGameCompany);
            if (toTeam > 0) usdt.safeTransfer(team, toTeam);
        }

        if (participants > 0) {
            if (eligibleShares == 0) {
                // Nobody is bonded. Send the participant share back rather
                // than stranding it in a pool with no claimants.
                usdt.safeTransfer(msg.sender, participants);
                participants = 0;
            } else {
                accUsdtPerShare += Math.mulDiv(participants, ACC_PRECISION, eligibleShares);
                totalUsdtDistributed += participants;
            }
        }

        if (hcowToDeduct > 0) {
            // totalShares is non-zero: hcowToDeduct is zero when it is not.
            accDeductedPerShare += Math.mulDiv(hcowToDeduct, ACC_PRECISION, totalShares);
            // Record the decay so a pending unbond, whichever way it leaves,
            // is charged for exactly the settlements it sat through. The rate
            // is used rather than the rounded amount so that the index means
            // the same thing for the bonded pool and for pending positions.
            uint256 nextIndex = Math.mulDiv(poolIndex, PPM_DENOM - deductPpm, PPM_DENOM);
            if (nextIndex == 0) nextIndex = 1;

            // Roll the window forward first, then hold the settlement to the
            // ceiling it implies. A per settlement cap bounds a mistake; this
            // is what bounds a campaign.
            if (decayWindowAt == 0 || block.timestamp >= decayWindowAt + DECAY_WINDOW) {
                decayWindowAt = uint64(block.timestamp);
                decayWindowBurned = 0;
            }
            uint256 windowCap =
                Math.mulDiv(totalBondedHcow, MAX_DECAY_PER_WINDOW_PPM, PPM_DENOM);
            uint256 wouldBe = decayWindowBurned + hcowToDeduct;
            if (wouldBe > windowCap) revert DecayWindowExhausted(windowCap, wouldBe);
            decayWindowBurned = wouldBe;
            poolIndex = nextIndex;
            totalBondedHcow -= hcowToDeduct;
            totalHcowDeducted += hcowToDeduct;
            hcow.safeTransfer(BURN_ADDRESS, hcowToDeduct);
        }

        // This epoch's arrivals start earning from the next one. Recording
        // the accumulator here is what lets an untouched account be promoted
        // later without losing the epochs in between.
        accAtEpoch[epoch] = accUsdtPerShare;
        poolIndexAtEpoch[epoch] = poolIndex;
        totalNewShares = 0;
        lastSettledAt = uint64(block.timestamp);

        _settlements[epoch] = Settlement({
            grossReceivedUsdt: grossReceivedUsdt.toUint128(),
            directCostsUsdt: directCostsUsdt.toUint128(),
            operatingCostsUsdt: operatingCostsUsdt.toUint128(),
            distributableProfitUsdt: profit.toUint128(),
            participantsUsdt: participants.toUint128(),
            hcowDeducted: hcowToDeduct.toUint128(),
            snapshotBondedHcow: snapshot.toUint128(),
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
        uint256 elig = uint256(a.shares) - uint256(a.newShares);
        uint256 accrued = Math.mulDiv(elig, accUsdtPerShare, ACC_PRECISION);
        uint256 total = a.claimableUsdt + (accrued > a.rewardDebt ? accrued - a.rewardDebt : 0);
        if (a.newShares > 0 && nextEpoch > a.newSharesEpoch) {
            uint256 startAcc = accAtEpoch[a.newSharesEpoch];
            if (accUsdtPerShare > startAcc) {
                total += Math.mulDiv(uint256(a.newShares), accUsdtPerShare - startAcc, ACC_PRECISION);
            }
        }
        return total;
    }

    /// @notice Shares that are earning right now. Anything bonded during the
    ///         open epoch is principal but does not earn until it closes.
    function eligibleSharesOf(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        if (a.newShares > 0 && nextEpoch > a.newSharesEpoch) return a.shares;
        return uint256(a.shares) - uint256(a.newShares);
    }

    /// @notice HCOW a pending unbond would actually pay out right now, after
    ///         the deductions it has sat through. `pendingUnbond` in
    ///         `accountOf` is the amount as requested, before that charge.
    function pendingUnbondOf(address account) public view returns (uint256) {
        Account storage a = _accounts[account];
        uint256 amount = a.pendingUnbond;
        if (amount == 0 || a.unbondIndex == 0) return amount;
        uint256 payout = Math.mulDiv(amount, _chargeIndex(a), a.unbondIndex);
        return payout > amount ? amount : payout;
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
            uint256 accrued = Math.mulDiv(s, accDeductedPerShare, ACC_PRECISION);
            if (accrued > a.deductDebt) deductedHcow += accrued - a.deductDebt;
        }
        claimedUsdt = a.lifetimeClaimedUsdt;
    }

    function getSettlement(uint64 epoch) external view returns (Settlement memory) {
        return _settlements[epoch];
    }

    /// @notice Maximum opex that would be accepted for a given revenue pair.
    /// @notice HCOW a settlement at this rate would consume right now.
    ///         The settler converts the published value rule into a rate and
    ///         checks it here before signing.
    function deductionFor(uint32 deductPpm) external view returns (uint256) {
        if (deductPpm > MAX_DEDUCT_PPM || totalShares == 0) return 0;
        // Mirrors the gate in settleEpoch: with nobody eligible the epoch
        // cannot consume principal, so the honest preview is zero.
        if (totalShares == totalNewShares) return 0;
        return (totalBondedHcow * deductPpm) / PPM_DENOM;
    }

    /// @notice When the next epoch may be settled. Zero if it may be now.
    function epochOpensAt() external view returns (uint64) {
        if (lastSettledAt == 0) return 0;
        uint64 openAt = lastSettledAt + uint64(MIN_EPOCH_INTERVAL);
        return block.timestamp >= openAt ? 0 : openAt;
    }

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
        uint256 elig = s - uint256(a.newShares);
        if (elig > 0) {
            uint256 usdtAccrued = Math.mulDiv(elig, accUsdtPerShare, ACC_PRECISION);
            if (usdtAccrued > a.rewardDebt) {
                a.claimableUsdt += usdtAccrued - a.rewardDebt;
            }
        }
        // Promote this epoch's arrivals once a settlement has passed over
        // them, crediting every epoch since from the recorded accumulator.
        if (a.newShares > 0 && nextEpoch > a.newSharesEpoch) {
            uint256 startAcc = accAtEpoch[a.newSharesEpoch];
            if (accUsdtPerShare > startAcc) {
                a.claimableUsdt +=
                    Math.mulDiv(uint256(a.newShares), accUsdtPerShare - startAcc, ACC_PRECISION);
            }
            a.newShares = 0;
            a.newSharesEpoch = 0;
        }
        // Deduction applies to every share from the moment it exists. New
        // shares are principal in the pool, so they absorb usage like any
        // other, and only the USDT leg waits.
        if (s > 0) {
            uint256 deducted = Math.mulDiv(s, accDeductedPerShare, ACC_PRECISION);
            if (deducted > a.deductDebt) {
                a.settledDeducted += deducted - a.deductDebt;
            }
        }
        _bookmark(a);
    }

    /**
     * @dev poolIndex as of the first settlement after the unbond was
     *      requested. Exactly one, and the same one whichever door the
     *      position leaves by.
     *
     * Two failure modes sit either side of this. Charging every settlement
     * forever punishes a holder who is simply slow to press withdraw, without
     * bound, for usage their HCOW did not back. Charging none of them makes
     * the withdraw door strictly cheaper than the cancel door, so nobody ever
     * cancels and stepping out around a settlement becomes free again, which
     * is the dodge the whole mechanism exists to close. One settlement,
     * priced the same both ways, is the only version that is neither.
     */
    function _chargeIndex(Account storage a) private view returns (uint256) {
        uint64 e = a.unbondEpoch;
        if (e < nextEpoch && poolIndexAtEpoch[e] != 0) return poolIndexAtEpoch[e];
        return a.unbondIndex;
    }

    /// @dev Record freshly minted shares as this epoch's arrivals. Call after
    ///      _settle, which guarantees any older batch has already been
    ///      promoted, so newSharesEpoch always refers to the open epoch.
    function _markNew(Account storage a, uint256 minted) private {
        a.newShares += minted.toUint128();
        a.newSharesEpoch = nextEpoch;
        totalNewShares += minted;
    }

    function _bookmark(Account storage a) private {
        uint256 s = uint256(a.shares);
        a.rewardDebt = Math.mulDiv(s - uint256(a.newShares), accUsdtPerShare, ACC_PRECISION);
        a.deductDebt = Math.mulDiv(s, accDeductedPerShare, ACC_PRECISION);
    }
}
