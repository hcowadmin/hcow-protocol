// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
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
 *   - Rule 5, the deduction rate limit. The settler no longer passes an HCOW
 *     amount. It passes a rate in parts per million, capped at MAX_DEDUCT_PPM,
 *     and the contract computes the amount from its own pool figure. With
 *     MIN_EPOCH_INTERVAL between settlements the worst case is 2% per week,
 *     and a position that requests an unbond is charged for at most one
 *     settlement, so reacting costs at most 2% of principal. Over a decay
 *     window MAX_DECAY_PER_WINDOW_PPM binds instead. That window is fixed
 *     rather than sliding and it is anchored by the FIRST deduction in it,
 *     so a settler chooses where the boundary falls and two windows can be
 *     packed back to back. The true worst case over an arbitrary span is
 *     therefore more than 3%: 59,999 ppm summed, 5.871% compounded, over
 *     any thirty days, and 70,000 ppm summed, 6.822% compounded, over any
 *     thirty seven. The derivation is at MAX_DECAY_PER_WINDOW_PPM below.
 *     Those are bounds the code enforces, not promises, and the figures to
 *     quote are the worst case ones, not the per window one.
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
     * @notice Floor on the pool the participant leg is measured against.
     *
     * Below this floor the eligible pool stops being a meaningful description
     * of a participant base: one wei bonded before anybody else, with a ten
     * million HCOW cohort arriving during the epoch, would otherwise take the
     * entire distribution, because the cohort is quarantined and the wei is all
     * that is left. Measured at 300,000 USDT to one wei.
     *
     * Two things changed here after audit.
     *
     * The floor was 1,000e18, one two-hundred-thousandth of supply, which is
     * not a pool. A sole participant holding exactly that took the whole
     * distribution with no manipulation at all. It is now 1,000,000e18, half a
     * percent of supply, which cannot be reached without a real position.
     *
     * It was also armed only while the previous settlement's snapshot was
     * itself below the floor. That condition could never be false when the
     * first was true, because the eligible pool only ever shrinks between
     * settlements, so it was dead code. What it did do was let the guard be
     * switched off: park a position above the floor across one settlement,
     * withdraw, and every settlement afterwards saw the guard disarmed. The
     * floor now looks at the pool in front of it and nothing else.
     *
     * Raising it is only safe because of what happens to the part the pool
     * cannot take. It used to go to the two fixed recipients, which charged
     * honest early participants for the guard's existence: a sole holder of
     * 999 tokens received 500 tokens less than the full leg and the difference
     * left the participant side for good. It now carries into the next epoch's
     * participant pot instead, so a small pool is paid later rather than less.
     *
     * It is set at deployment rather than compiled in. A single constant
     * cannot describe "a real pool" for every deployment, and the audit's
     * objection to the old value was exactly that it did not describe one here.
     * Fixed at construction it is still not a lever: nobody can move it
     * afterwards and it is readable on chain. The bound below stops it being
     * set high enough to keep a real pool from ever being paid in full.
     *
     * The published mainnet value is 1,000,000e18, half a percent of supply.
     */
    uint256 public immutable minPoolShares;

    /// @notice Upper bound on minPoolShares, as a share of token supply at
    ///         deployment.
    uint256 public constant MAX_MIN_POOL_SHARES_BPS = 500; // 5%

    /**
     * @notice Ceiling on how long one epoch may stay open.
     *
     * MIN_EPOCH_INTERVAL bounds a settler that settles too often. Nothing
     * bounded one that stops: a settler that simply never calls settleEpoch
     * again leaves the current epoch open forever, and every deposit made into
     * it stays quarantined, earning nothing, while still carrying the full
     * deduction whenever a settlement eventually arrives. That is an open-ended
     * liveness dependency on a single key.
     *
     * Past this ceiling anyone may close the epoch with closeStalledEpoch,
     * which moves no money and cannot state a revenue figure. It ends the
     * quarantine and starts a fresh epoch, and that is all it does.
     */
    uint256 public constant MAX_EPOCH_INTERVAL = 30 days;

    /// @notice The same ceiling, before the first settlement has ever happened.
    ///         Longer, because a launch window with no revenue yet is normal
    ///         and abandonment is not: at thirty days a stranger could burn
    ///         several all-zero epochs during a perfectly healthy launch.
    uint256 public constant BOOTSTRAP_STALL_INTERVAL = 90 days;

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
     * @notice totalShares as it stood at the end of the previous settlement.
     *
     * NOT the denominator of the eligible fraction. It was, for one round of
     * fixes, and the comment that said so outlived the code by two rewrites.
     * Freezing the denominator to the epoch-start pool while the numerator
     * stayed live is what made the requestUnbond/cancelUnbond flip profitable,
     * so the divisor is now `max(eligibleShares, minPoolShares)` and this is
     * read by nothing in the contract at all.
     *
     * It is kept because it is the one figure that says what the pool looked
     * like when the epoch opened, which an observer cannot otherwise reconstruct
     * from events, and because both settlement paths write it so it never goes
     * stale. Treat it as published history, not as an input. A reviewer who
     * takes the old comment at face value will reason about the wrong divisor,
     * which is the whole reason this one is written out.
     */
    uint256 public sharesAtLastSettlement;

    /**
     * @notice USDT held back from a participant leg the eligible pool was too
     *         small to take, waiting for the next epoch.
     *
     * It is participant money that has not been paid yet, not protocol money.
     * It is added to the next epoch's participant pot before the fraction is
     * applied, so it is attributed to shares rather than sitting in a pot
     * somebody has to be trusted to release. The two fixed recipients never
     * receive it and there is no path by which anyone else can.
     */
    uint256 public carriedParticipantUsdt;

    /// @notice Set at construction, so a settler that never settles even once
    ///         still has a deadline attached to it.
    uint64 public immutable deployedAt;

    /// @notice Two-step ownership. A mistyped address ends control of the
    ///         settler role and both payout addresses permanently, so the
    ///         incoming address has to prove it exists first.
    address public pendingOwner;


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
     * @notice When the current decay window opened, and how much deduction
     *         rate has been spent inside it, in parts per million.
     *
     * Metered as a rate, with no reference to the size of the pool at all.
     *
     * Any ceiling computed against a pool figure can be moved by moving the
     * pool. Against a live figure a dominant holder shrinks it by requesting
     * an unbond, vetoes the settlement outright at no cost, and cancels.
     * Against a figure snapshotted when the window opened, capital parked for
     * one block inflates it and leaves. Against a figure that counts pending
     * unbonds, parking loosens the rate bound for everyone else. A rate has no
     * base to attack.
     *
     * What it bounds, precisely, is the bonded pool. A position that stays
     * bonded decays at this rate for every settlement it sits through, and
     * because deductPpm sums linearly while poolIndex compounds, actual
     * destruction is always below the meter. A pending unbond is a different
     * case and a weaker one: _chargeIndex charges it for AT MOST one
     * settlement however long it waits, so requesting an unbond is a
     * one-time-priced, permanent opt-out of all further deduction. That is
     * deliberate, it is what stops a settlement from being able to reach a
     * position that has already asked to leave, and it means the meter
     * overstates rather than understates what a campaign destroys.
     *
     * At most one, not exactly one. _chargeIndex prices a pending unbond
     * against poolIndexAtEpoch[unbondEpoch], the index written by whichever
     * call closes that epoch, and closeStalledEpoch is one of the two calls
     * that can close it. A stall close writes poolIndex unchanged because it
     * deducts nothing, so an unbond that was requested into an epoch nobody
     * ever settled is charged zero rather than one. That is the direction
     * that favours the holder, so it is left as it is, but the earlier
     * wording said "exactly one" and that was wrong.
     *
     * The window is fixed, not sliding, and decayWindowAt is written by the
     * FIRST deduction in a window rather than by the clock. A settler
     * therefore chooses where the boundary falls, and two windows can be
     * packed back to back. MIN_EPOCH_INTERVAL at seven days is what stops
     * two full windows landing inside thirty; it does not stop the packing.
     *
     * Worst case over an arbitrary thirty days, 59,999 ppm summed. Anchor a
     * window with 1 ppm at t0 so its budget is spent late: 20,000 at t0+16d
     * and 9,999 at t0+23d. The next window cannot anchor before t0+30d, so
     * anchor it there with 20,000 and spend 10,000 at t0+37d. The span
     * [t0+16d, t0+46d) holds all four. 60,000 is unreachable because it
     * would need both anchors inside one thirty day span and they are
     * thirty days apart. Compounded, 5.871%.
     *
     * Worst case over an arbitrary thirty seven days, 70,000 ppm summed. A
     * thirty seven day span can touch three windows: the tail of one
     * (20,000 at t0-7d), all of the next (20,000 at t0, 9,999 at t0+7d,
     * 1 at t0+14d), and the anchor of the one after (20,000 at t0+30d).
     * Compounded, 6.822%.
     *
     * Both figures are the meter, which sums linearly while poolIndex
     * compounds on a shrinking base, so actual destruction sits at or below
     * them. Quote 5.87% and 6.82%, not the 3% per window figure.
     */
    uint64 public decayWindowAt;
    uint256 public decayWindowPpm;

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
        uint128 gameCompanyUsdt;
        uint128 teamUsdt;
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
    /// @dev forfeited is HCOW burned on the way out. Without it in the log an
    ///      indexer cannot attribute the burn to an account, and a published
    ///      burn total built from settlements alone is short by this channel.
    event UnbondCancelled(
        address indexed account, uint256 hcowAmount, uint256 sharesMinted, uint256 forfeited
    );
    event Unbonded(address indexed account, uint256 hcowAmount, uint256 forfeited);
    event UsdtClaimed(address indexed account, uint256 amount);

    /**
     * @dev The two fixed legs are stated rather than left to be reconstructed.
     *      They are NOT a quarter of distributableProfitUsdt each: floor
     *      division puts up to two wei of dust on the team. An indexer applying
     *      the 25% rule to an odd profit figure gets a number that does not add
     *      up, which is exactly the reconciliation this event exists to make
     *      possible.
     *
     *      The identity is
     *
     *        distributableProfitUsdt
     *          = participantsUsdt + gameCompanyUsdt + teamUsdt
     *            + the change in carriedParticipantUsdt
     *
     *      exactly, in every branch. The carry term is zero in an ordinary
     *      epoch, positive when the eligible pool is below the floor, and
     *      negative when a real pool releases what was withheld. It is reported
     *      by ParticipantUsdtCarried and ParticipantUsdtReleased, so the
     *      reconciliation needs no storage read. The three legs alone stopped
     *      summing to the profit when the carry was introduced, and a comment
     *      that still said they did was worse than no comment.
     */
    event EpochSettled(
        uint64 indexed epoch,
        uint256 grossReceivedUsdt,
        uint256 directCostsUsdt,
        uint256 netRevenueUsdt,
        uint256 operatingCostsUsdt,
        uint256 distributableProfitUsdt,
        uint256 participantsUsdt,
        uint256 gameCompanyUsdt,
        uint256 teamUsdt,
        uint256 hcowDeducted,
        uint256 snapshotBondedHcow
    );

    event SettlerChanged(address indexed account);
    event RecipientsChanged(address indexed gameCompany, address indexed team);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed nominee);
    event StalledEpochClosed(uint64 indexed epoch, address indexed closedBy, uint64 openSince);
    /// @notice Part of an epoch's participant leg was withheld because the
    ///         eligible pool was below the floor, and is held for the first real
    ///         pool. `amount` is what this epoch added, `carriedTotal` the
    ///         running balance after it.
    event ParticipantUsdtCarried(uint64 indexed epoch, uint256 amount, uint256 carriedTotal);
    /// @notice A carried balance was released to a real pool. `amount` is what
    ///         this epoch paid out of the carry, `carriedTotal` what is left.
    event ParticipantUsdtReleased(uint64 indexed epoch, uint256 amount, uint256 carriedTotal);

    // ------------------------------------------------------------------
    // errors
    // ------------------------------------------------------------------

    error NotOwner();
    error NotSettler();
    error NotPendingOwner();
    error MinPoolSharesTooHigh(uint256 given, uint256 max);
    error EpochNotStalled(uint64 openAt);
    /// A settlement bringing money in while no shares exist at all. The
    /// participant half would be carried with nothing that could ever release
    /// it.
    error NoParticipantsToCarryFor();
    error ZeroAddress();
    error ZeroAmount();
    error WrongEpoch(uint64 expected, uint64 given);
    error CostsExceedRevenue();
    error OpexAboveCap(uint256 submitted, uint256 cap);
    error DeductionWithoutDistribution();
    error DeductionRateAboveCap(uint32 requested, uint32 cap);
    error EpochTooSoon(uint64 readyAt);
    error DecayWindowExhausted(uint256 windowCapPpm, uint256 wouldBePpm);
    error ProfitNotFunded(uint256 expected, uint256 arrived);
    error SameToken();
    error SettlerIsRecipient();
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
        address team_,
        uint256 minPoolShares_
    ) {
        if (
            hcowToken == address(0) || usdtToken == address(0) ||
            initialOwner == address(0) || initialSettler == address(0) ||
            gameCompany_ == address(0) || team_ == address(0)
        ) revert ZeroAddress();
        // One address for both tokens makes bonded principal and the
        // distribution currency the same balance: deposits become payouts.
        if (hcowToken == usdtToken) revert SameToken();
        // The settler funds the distribution out of its own balance. If it
        // also receives either fixed leg, half the cost of any published
        // figure comes straight back, and when nobody is eligible the whole
        // amount does. A settlement must cost the settler something.
        if (initialSettler == gameCompany_ || initialSettler == team_) {
            revert SettlerIsRecipient();
        }

        // The floor the participant leg is measured against. Zero would let a
        // single wei take an entire distribution; too high would keep a real
        // pool from ever being paid in full.
        if (minPoolShares_ == 0) revert ZeroAmount();
        {
            uint256 supply = IERC20Supply(hcowToken).totalSupply();
            if (supply == 0) revert ZeroAmount();
            if (minPoolShares_ > (supply * MAX_MIN_POOL_SHARES_BPS) / 10_000) {
                revert MinPoolSharesTooHigh(minPoolShares_, (supply * MAX_MIN_POOL_SHARES_BPS) / 10_000);
            }
        }
        minPoolShares = minPoolShares_;

        hcow = IERC20(hcowToken);
        usdt = IERC20(usdtToken);
        deployedAt = uint64(block.timestamp);
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

        // Burn shares proportional to the HCOW being pulled out, rounded UP.
        //
        // The pool's price is totalBondedHcow / totalShares. This function
        // removes exactly `hcowAmount` from the numerator, so it must remove at
        // least the proportional share count from the denominator or the price
        // falls and the difference is taken from everyone who stayed. Floored,
        // it fell: measured, one wei requested and immediately cancelled moved
        // one wei of bonded HCOW from another holder to the caller, repeatably.
        // A wei per transaction is not worth the gas to steal, but a pool price
        // that drifts down on every exit is the shape that cost Balancer 128
        // million dollars in November 2025, and there is no reason to ship it.
        //
        // Rounding up costs the caller at most one share, which is worth less
        // than one wei of HCOW, and it is the direction that favours the pool.
        // It cannot exceed the caller's balance: at hcowAmount == owned it is
        // exactly a.shares, and below that it is strictly less.
        uint256 sharesToBurn = Math.mulDiv(hcowAmount, uint256(a.shares), owned, Math.Rounding.Ceil);
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

        emit UnbondCancelled(msg.sender, restored, minted, forfeited);
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
        emit Unbonded(msg.sender, payout, forfeited);
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
        {
            uint256 cap = (netRevenue * OPEX_CAP_BPS) / 10_000;
            if (operatingCostsUsdt > cap) revert OpexAboveCap(operatingCostsUsdt, cap);
        }

        uint256 profit = netRevenue - operatingCostsUsdt;
        uint256 eligibleShares = totalShares - totalNewShares;

        // Rule 2. A settlement that brings money in needs somebody for the
        // participant half to eventually reach.
        //
        // With no shares outstanding at all, the participant leg is carried,
        // and the carry's only exit is a later settlement with a non-empty
        // eligible pool. If nobody ever bonds again it is unreachable forever:
        // there is no sweep, no owner rescue, and `claimUsdt` cannot see it.
        // Measured on the version without this check: the last participant
        // withdrew, the settler kept settling, and 200,000 USDT accumulated
        // that nobody had any claim on, while the two fixed recipients were
        // paid their quarters in full each time and so had no signal that
        // anything was wrong.
        //
        // `totalShares == 0` is the precise condition, and it is not the
        // launch case. During the launch window a bonded position exists and
        // is merely quarantined, so `totalShares > 0` while `eligibleShares`
        // is 0, the leg is carried, and the first settlement lifts the
        // quarantine exactly as intended. Testing `eligibleShares` here
        // instead would deadlock that.
        //
        // An epoch with no revenue is still allowed, so the settler can always
        // advance the sequence.
        if (profit > 0 && totalShares == 0) revert NoParticipantsToCarryFor();

        // The waterfall is a function of its arguments and nothing else. It
        // was inline, at a measured branch complexity of twenty-one across
        // roughly two hundred lines, and several of this contract's historical
        // findings lived in the ordering between the distribution gate and the
        // leg scaling. Separating it makes that ordering visible at a glance
        // and costs nothing at runtime.
        uint256 participants;
        uint256 toGameCompany;
        uint256 toTeam;
        (participants, toGameCompany, toTeam) =
            _waterfall(profit, eligibleShares, carriedParticipantUsdt);

        // Rule 5. The rate is capped, and two deductions cannot be stacked
        // inside the cooldown. Together these bound the worst case at 2% a week.
        if (deductPpm > MAX_DEDUCT_PPM) {
            revert DeductionRateAboveCap(deductPpm, MAX_DEDUCT_PPM);
        }
        // Rules 4 and 6, as one test, on THIS epoch's own contribution to
        // participants.
        //
        // Two earlier versions of this gate were wrong in the same way, and the
        // second was introduced by the fix for the first. Testing the computed
        // leg let a settlement whose eligible pool is a rounding error burn the
        // whole pool's worth of principal while crediting nothing. Testing the
        // credited figure fixed that and opened a worse hole once the carry
        // existed: `participants` is computed on `participantLeg + carried`, so
        // a balance withheld from earlier epochs satisfies the gate on behalf
        // of an epoch that brought in almost nothing. Adding `profit != 0` in
        // front of it did not close that, because one wei is not zero.
        // Measured on that version: a carry of 300,000 USDT let a settlement
        // funded with ONE WEI burn 200,000 HCOW of participant principal.
        //
        // `_epochCredit` is what this epoch's own revenue actually puts in
        // participants' hands, with the carry excluded. Principal is consumed
        // only when that figure is meaningful on its own.
        //
        // THE COST, in the other direction, stated so the next person to touch
        // this does not "fix" it by putting the carry back in. An epoch that
        // pays participants a large REAL distribution out of a carried balance
        // still cannot take a deduction if its own revenue is under two USDT:
        // measured, 300,000 USDT carried, the next settlement funded with one
        // USDT credits 300,000.5 and is refused any deduction. That is a delay,
        // not a loss. The settler settles it at deductPpm zero and takes the
        // deduction the following epoch. Letting the carry satisfy the gate is
        // what made one wei buy a full two percent burn, and no framing of it
        // is safe.
        //
        // With nobody eligible the leg is carried rather than credited, so
        // there is nothing to charge and nothing to charge it against, and the
        // deduction is dropped rather than the settlement refused: a single
        // dominant holder could otherwise veto every settlement by front
        // running it with an unbond request.
        if (
            deductPpm != 0 &&
            eligibleShares != 0 &&
            _epochCredit(profit, eligibleShares) < MIN_PARTICIPANT_USDT
        ) {
            revert DeductionWithoutDistribution();
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
            //
            // The two payouts do NOT happen here. They are the last thing this
            // function does, after every piece of state is written. See the
            // block at the end.
            uint256 beforeUsdt = usdt.balanceOf(address(this));
            usdt.safeTransferFrom(msg.sender, address(this), profit);
            uint256 arrived = usdt.balanceOf(address(this)) - beforeUsdt;
            if (arrived != profit) revert ProfitNotFunded(profit, arrived);
        }

        if (participants > 0) {
            accUsdtPerShare += Math.mulDiv(participants, ACC_PRECISION, eligibleShares);
            totalUsdtDistributed += participants;
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
                decayWindowPpm = 0;
            }
            uint256 wouldBe = decayWindowPpm + deductPpm;
            if (wouldBe > MAX_DECAY_PER_WINDOW_PPM) {
                revert DecayWindowExhausted(MAX_DECAY_PER_WINDOW_PPM, wouldBe);
            }
            decayWindowPpm = wouldBe;
            poolIndex = nextIndex;
            totalBondedHcow -= hcowToDeduct;
            totalHcowDeducted += hcowToDeduct;
        }

        // This epoch's arrivals start earning from the next one. Recording
        // the accumulator here is what lets an untouched account be promoted
        // later without losing the epochs in between.
        {
            // Whatever the eligible pool was too small to take stays here for
            // the next epoch. It never reaches the two fixed recipients.
            uint256 prior = carriedParticipantUsdt;
            uint256 newCarry = (profit * PARTICIPANT_BPS) / 10_000 + prior - participants;
            if (newCarry != prior) {
                carriedParticipantUsdt = newCarry;
                // The direction is reported, and the amount is the change
                // rather than the running total. The first version passed the
                // total in both fields and fired on every epoch where a carry
                // merely survived, so an indexer summing `amount` got nonsense
                // and the most interesting moment, the release, was silent.
                if (newCarry > prior) {
                    emit ParticipantUsdtCarried(epoch, newCarry - prior, newCarry);
                } else {
                    emit ParticipantUsdtReleased(epoch, prior - newCarry, newCarry);
                }
            }
        }

        accAtEpoch[epoch] = accUsdtPerShare;
        poolIndexAtEpoch[epoch] = poolIndex;
        totalNewShares = 0;
        // The pool the next epoch begins with. Written after the deduction so
        // it reflects the share count, which the deduction does not change.
        sharesAtLastSettlement = totalShares;
        lastSettledAt = uint64(block.timestamp);

        _settlements[epoch] = Settlement({
            grossReceivedUsdt: grossReceivedUsdt.toUint128(),
            directCostsUsdt: directCostsUsdt.toUint128(),
            operatingCostsUsdt: operatingCostsUsdt.toUint128(),
            distributableProfitUsdt: profit.toUint128(),
            participantsUsdt: participants.toUint128(),
            gameCompanyUsdt: toGameCompany.toUint128(),
            teamUsdt: toTeam.toUint128(),
            hcowDeducted: hcowToDeduct.toUint128(),
            snapshotBondedHcow: snapshot.toUint128(),
            settledAt: uint64(block.timestamp)
        });

        nextEpoch = epoch + 1;

        emit EpochSettled(
            epoch, grossReceivedUsdt, directCostsUsdt, netRevenue,
            operatingCostsUsdt, profit, participants, toGameCompany, toTeam,
            hcowToDeduct, snapshot
        );

        // ---- interactions, last ----
        //
        // Checks, effects, interactions, in that order. Every piece of state
        // above is written before any of these three transfers runs.
        //
        // The incoming transferFrom has to be first, because the amount that
        // actually arrives is an input to the arithmetic; that is a pull, and
        // pulls before effects are the normal shape. These three are pushes,
        // and they were previously interleaved with the accumulator and pool
        // writes. `nonReentrant` covered it and neither token has a transfer
        // hook, so nothing was exploitable, but "not exploitable given two
        // facts about the deployment" is a weaker statement than "ordered
        // correctly", and this is the one place in the contract where the
        // ordering was not free. It is now.
        if (toGameCompany > 0) usdt.safeTransfer(gameCompany, toGameCompany);
        if (toTeam > 0) usdt.safeTransfer(team, toTeam);
        if (hcowToDeduct > 0) hcow.safeTransfer(BURN_ADDRESS, hcowToDeduct);
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
     *
     * @dev deductedHcow includes deduction that has accrued but has not yet
     *      been folded in by a state-changing call, so it is correct between
     *      settlements without anyone having to poke the contract.
     *
     *      It is an upper bound, not an exact figure. The per-share accumulator
     *      rounds the account's share of each deduction up rather than down, so
     *      the sum of every account's `deductedHcow` can exceed
     *      `totalHcowDeducted` by up to one wei per account per settlement. The
     *      direction is deliberate and is not changed: rounding the charge down
     *      instead would let an account be charged less than its share, which
     *      is a leak that compounds across settlements, while rounding up costs
     *      an account at most a wei it never actually loses, because the wei is
     *      never taken from the pool. Any figure published from this getter
     *      should be described as at most this much, and reconciliation against
     *      `totalHcowDeducted` should allow that slack rather than assert
     *      equality.
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
        if (account == address(0) || account == address(this)) revert ZeroAddress();
        if (account == gameCompany || account == team) revert SettlerIsRecipient();
        settler = account;
        emit SettlerChanged(account);
    }

    /// @dev The two 25% recipients. They may be the same address as each
    ///      other, but neither may be the settler: a settlement has to cost
    ///      the settler something, or any revenue figure can be published for
    ///      free and the published waterfall stops meaning anything.
    function setRecipients(address gameCompany_, address team_) external onlyOwner {
        // address(this) alongside address(0), because it is the same kind of
        // mistake with a worse ending. A recipient set to this contract makes
        // every settlement execute usdt.safeTransfer(address(this), ...), a
        // valid self transfer that raises the balance above what
        // accUsdtPerShare accounts for. There is no sweep and no owner rescue,
        // so that USDT is unreachable by claimUsdt forever. It costs one
        // comparison to make unreachable in the first place, and HCOWVesting
        // already refuses address(this) as a beneficiary for the same reason.
        if (gameCompany_ == address(0) || team_ == address(0)) revert ZeroAddress();
        if (gameCompany_ == address(this) || team_ == address(this)) revert ZeroAddress();
        if (gameCompany_ == settler || team_ == settler) revert SettlerIsRecipient();
        gameCompany = gameCompany_;
        team = team_;
        emit RecipientsChanged(gameCompany_, team_);
    }

    /**
     * @notice Step one of two. The new owner is not the owner until it accepts.
     *
     * @dev A single step wrote the address immediately, so a mistyped or
     *      unreachable one ended the ability to rotate the settler or change
     *      either payout address, permanently and with no recovery. The vesting
     *      contract already worked this way; this makes the codebase agree with
     *      itself.
     *
     *      setSettler and setRecipients stay single step deliberately. Both are
     *      recoverable by a live owner, both are read straight off an explorer,
     *      and the runbook requires the owner key to be a multisig, which is
     *      what stops a mistyped address being submitted without review.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Withdraw a standing nomination without handing the role to
    ///         anyone. `transferOwnership(address(0))` is refused, so without
    ///         this the only way to cancel was to nominate the current owner
    ///         and accept, which leaves a live pending administrator visible on
    ///         an explorer in the meantime and is not something an operator who
    ///         has just typed the wrong address will find.
    function cancelOwnershipTransfer() external onlyOwner {
        address was = pendingOwner;
        if (was == address(0)) revert ZeroAddress();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(was);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    /**
     * @notice Closes an epoch that has been left open past MAX_EPOCH_INTERVAL.
     *         Permissionless.
     *
     * @dev MIN_EPOCH_INTERVAL bounded a settler that settled too often. Nothing
     *      bounded one that stopped. A settler that simply never calls
     *      settleEpoch again leaves the epoch open forever, and every deposit
     *      made into it stays quarantined, earning nothing, while still
     *      carrying the full deduction whenever a settlement eventually
     *      arrives. Depositors could withdraw after the cooldown, but nobody
     *      could advance the period.
     *
     *      This moves no money. It states no revenue figure: every one is
     *      hard-coded zero here, so a caller cannot author a settlement, and
     *      with zero profit no principal can be consumed either. All it does is
     *      end the quarantine and open the next epoch.
     *
     *      It gives an impatient depositor nothing they could not already get
     *      by waiting for the settler, and it costs a griefer gas to advance an
     *      epoch that pays nobody. Because MAX_EPOCH_INTERVAL is longer than
     *      MIN_EPOCH_INTERVAL, closing a stalled epoch never lets the settler
     *      settle sooner than it otherwise could have.
     */
    function closeStalledEpoch() external nonReentrant {
        // Two fuses, and the one before the first settlement is much longer.
        //
        // At thirty days from deployment a stranger could close epoch 0 during
        // the launch window with no participant, no revenue and nothing wrong,
        // and then one every thirty days after: measured, four epochs burned as
        // all-zero records before the operator had settled anything, each
        // pushing that settlement out by another MIN_EPOCH_INTERVAL.
        //
        // Refusing the path outright until the first settlement was the
        // obvious fix and it opened a liveness hole instead: a settler that
        // never settles even once leaves nextEpoch at zero forever, every
        // bonded position quarantined and earning nothing, with no
        // permissionless call able to advance anything however long anyone
        // waits. Principal still leaves through requestUnbond at no charge, so
        // it is not a loss, but it is unrecoverable in a contract whose whole
        // point is that nobody has to wait on the operator.
        //
        // Ninety days from deployment with no settlement at all is not a launch
        // window, it is abandonment.
        uint64 openedAt = lastSettledAt;
        uint64 deadline = openedAt == 0
            ? deployedAt + uint64(BOOTSTRAP_STALL_INTERVAL)
            : openedAt + uint64(MAX_EPOCH_INTERVAL);
        if (block.timestamp < deadline) revert EpochNotStalled(deadline);

        uint64 epoch = nextEpoch;
        uint256 snapshot = totalBondedHcow;

        accAtEpoch[epoch] = accUsdtPerShare;
        poolIndexAtEpoch[epoch] = poolIndex;
        totalNewShares = 0;
        sharesAtLastSettlement = totalShares;
        lastSettledAt = uint64(block.timestamp);

        _settlements[epoch] = Settlement({
            grossReceivedUsdt: 0,
            directCostsUsdt: 0,
            operatingCostsUsdt: 0,
            distributableProfitUsdt: 0,
            participantsUsdt: 0,
            gameCompanyUsdt: 0,
            teamUsdt: 0,
            hcowDeducted: 0,
            snapshotBondedHcow: snapshot.toUint128(),
            settledAt: uint64(block.timestamp)
        });

        nextEpoch = epoch + 1;

        // Deliberately NOT EpochSettled. An epoch closed by a stranger because
        // the settler stopped is not a settlement, and emitting the settlement
        // event with every figure at zero made the two indistinguishable to
        // anything reading events. Consumers that need every epoch should read
        // getSettlement, which still returns the zero record.
        emit StalledEpochClosed(epoch, msg.sender, openedAt);
    }

    /// @notice When the current epoch may be closed by anyone. Reaching this
    ///         without a settlement is the liveness failure the ceiling exists
    ///         for, not a normal state.
    /// @notice When the open epoch may be closed by anyone.
    function epochStallDeadline() external view returns (uint64) {
        if (lastSettledAt == 0) return deployedAt + uint64(BOOTSTRAP_STALL_INTERVAL);
        return lastSettledAt + uint64(MAX_EPOCH_INTERVAL);
    }

    // ------------------------------------------------------------------
    // internal
    // ------------------------------------------------------------------

    /**
     * @notice Splits one epoch's profit. Pure: no storage, no time, no caller.
     *
     * @param profit          Distributable profit for the epoch.
     * @param eligibleShares  Shares that were not bonded during this epoch.
     * @param carried         Participant money held back from earlier epochs.
     *
     * @return participants   Credited to the eligible pool now.
     * @return toGameCompany  The fixed quarter. Never more than that.
     * @return toTeam         The fixed quarter, plus rounding dust.
     *
     * Whatever the pool was too small to take is `participantLeg + carried -
     * participants`. It is derived again at the write site rather than returned
     * here, because one more return value put settleEpoch over the stack limit.
     *
     * @dev Three divisors were tried before this one and each was worse. The
     *      live share count let anyone shrink the eligible fraction by bonding
     *      in the settlement block: measured, an honest holder's 100,000 USDT
     *      leg became 100. Freezing the denominator to the epoch-start pool
     *      moved the same attack to the numerator, because requestUnbond
     *      followed by cancelUnbond in one block removes a position from
     *      eligibleShares and puts it back as new shares at zero cost:
     *      measured, 150 USDT of a 300,000 USDT leg reached participants. And
     *      any divisor larger than eligibleShares hands the difference away
     *      whenever somebody simply leaves mid epoch, which is an ordinary user
     *      action: a holder exiting a 50/50 pool moved the split from 50/25/25
     *      to 25/37.5/37.5.
     *
     *      Dividing by eligibleShares itself removes the lever entirely, and
     *      minPoolShares stops the degenerate end of it.
     *
     * @dev What the floor holds back is carried, not given away. Sending it to
     *      the two fixed recipients charged honest early participants for the
     *      guard: a sole holder of 999 tokens received 500 less than the leg and
     *      the difference left the participant side permanently. Holding it in a
     *      separate claimable pot was tried earlier and was worse, because a pot
     *      has no link to the shares it was deferred for and one wei bonded
     *      after everybody left collects the lot. Folding it into the next
     *      epoch's pot before the fraction is applied attributes it to shares
     *      instead, which is what makes it safe.
     *
     *      Returning it to the settler was also tried and is self dealing: the
     *      settler both authors the revenue figure and can move the divisor.
     *      Measured at 999 times the pool, a settler recovered 49,950 of a
     *      50,000 USDT participant leg and unbonded a week later at no cost.
     *
     * @dev The two fixed recipients now receive exactly their own quarter and
     *      nothing else, in every branch. That is a change: they used to
     *      collect whatever the participant pool could not take.
     */
    /**
     * @dev What THIS epoch's revenue alone credits to participants, with any
     *      carried balance excluded. The deduction gate tests this rather than
     *      the credited total, because the credited total can be carried money.
     *      Same scaling as `_waterfall`, applied to this epoch's leg only.
     */
    function _epochCredit(uint256 profit, uint256 eligibleShares)
        private
        view
        returns (uint256)
    {
        if (eligibleShares == 0) return 0;
        uint256 leg = (profit * PARTICIPANT_BPS) / 10_000;
        uint256 floor_ = minPoolShares;
        uint256 denom = eligibleShares < floor_ ? floor_ : eligibleShares;
        return Math.mulDiv(leg, eligibleShares, denom);
    }

    function _waterfall(uint256 profit, uint256 eligibleShares, uint256 carried)
        private
        view
        returns (uint256 participants, uint256 toGameCompany, uint256 toTeam)
    {
        uint256 participantLeg = (profit * PARTICIPANT_BPS) / 10_000;
        uint256 pot = participantLeg + carried;

        // The floor looks at the pool in front of it and nothing else. It used
        // to be armed only while the previous settlement's snapshot was also
        // below the floor, which could never be false when the pool was, so it
        // was dead code that could nonetheless be switched off: park a position
        // above the floor across one settlement, withdraw, and the guard stayed
        // disarmed from then on.
        uint256 floor_ = minPoolShares;
        uint256 denom = eligibleShares < floor_ ? floor_ : eligibleShares;

        participants = eligibleShares == 0 ? 0 : Math.mulDiv(pot, eligibleShares, denom);
        // What the pool could not take is `pot - participants`. It is derived
        // again at the write site rather than returned, because one more
        // return value put settleEpoch over the stack limit.

        toGameCompany = (profit * GAME_COMPANY_BPS) / 10_000;
        // The remainder of the profit after the other two legs, so rounding
        // dust never strands and participants + gameCompany + team + newCarry
        // reconstructs profit + carried exactly in every branch.
        toTeam = profit - participantLeg - toGameCompany;
    }

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
        // Rounded up, deliberately. The credit at _settle is
        // floor(s * accNow) - rewardDebt, so a rewardDebt that was itself
        // floored lets every share count change credit up to one wei more than
        // the pool actually received. The contract retains exactly what it
        // distributed, so there is no cushion: measured, the gap opened at
        // epoch 7 of a 40 epoch run and the last holder's claim reverted with
        // ERC20InsufficientBalance, stranding 5.137 USDT until somebody
        // donated a wei. Rounding the debt up costs a claimant at most one wei
        // and makes the shortfall unreachable.
        a.rewardDebt = Math.mulDiv(
            s - uint256(a.newShares), accUsdtPerShare, ACC_PRECISION, Math.Rounding.Ceil
        );
        // Rounded up for the same reason as rewardDebt above. This one is a
        // published figure rather than a payout, so a drift here cannot strand
        // anyone's money, but it can make the sum of every account's lifetime
        // deduction exceed the burn that actually happened, and a reconciliation
        // that does not reconcile is its own kind of defect.
        a.deductDebt = Math.mulDiv(s, accDeductedPerShare, ACC_PRECISION, Math.Rounding.Ceil);
    }
}
