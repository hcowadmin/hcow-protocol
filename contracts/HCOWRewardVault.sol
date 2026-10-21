// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHCOWStakingFunding {
    function hcow() external view returns (IERC20);
    function rewardFunder() external view returns (address);
    function fundRewards(uint256 amount, uint64 duration) external;
}

/**
 * @title HCOWRewardVault
 * @notice Holding point between Profit Share and the staking reward stream.
 *
 * WHY IT EXISTS
 *   HCOWProfitShare sends 70% of every HCOW amount it consumes here: the
 *   settlement deduction and the forfeit charged to a pending unbond. It does
 *   not call HCOWStaking.fundRewards itself. fundRewards refuses a duration
 *   below the floor or a funding that would slow the running stream, and a
 *   settlement that could revert on a rule of another contract would make
 *   Profit Share's liveness depend on that contract's state. A plain ERC20
 *   transfer into this vault cannot fail for that reason, so the settlement
 *   always completes and the streaming is a separate call.
 *
 * WHAT THE CHAIN ENFORCES
 *   - HCOW leaves this contract by exactly one path: HCOWStaking.fundRewards,
 *     on the staking contract fixed at construction. There is no withdraw, no
 *     sweep, no rescue and no owner transfer of tokens. The approval is
 *     granted for the exact amount immediately before the call and cleared
 *     immediately after it, and the balance change is checked against it.
 *   - The keeper chooses when to stream and over how long, within
 *     MIN_DURATION and MAX_DURATION, and within HCOWStaking's own floors. The
 *     keeper cannot choose where the tokens go.
 *   - The owner can only replace the keeper and hand over ownership.
 *
 * WHAT IT CANNOT ENFORCE
 *   - That the keeper streams at all. A keeper that does nothing leaves the
 *     HCOW here, intact, until the owner appoints one that does. That is a
 *     delay, not a loss.
 *   - That the keeper streams well. HCOWStaking never lets a funding end
 *     before the running period or slow its rate, so whatever end date the
 *     keeper sets binds every later funding until it passes, and replacing
 *     the keeper does not undo it. A dust amount over a long duration is the
 *     worst case: every later deposit is stretched onto that end date. That
 *     is why MAX_DURATION is thirty days and not staking's year. Measured
 *     against a year it stretched delivery fifty two fold for twelve months;
 *     at thirty days the damage is bounded by thirty days.
 *
 * OPERATING THE KEEPER
 *   Call fund() at or after staking.periodFinish(), with the whole balance,
 *   over MIN_DURATION. Inside the tail of a live period staking requires the
 *   new amount to keep the running rate over the new duration, which a
 *   smaller deposit than the last one does not, and a refused call costs the
 *   week. During a live period never pass less than the time remaining.
 *   - That this vault stays the staking contract's rewardFunder. The staking
 *     owner can move the role elsewhere, and while it is elsewhere fund()
 *     reverts with NotFunder and the HCOW waits here. isLive() reports it.
 *   - Tokens other than HCOW sent here by mistake are unreachable. A sweep
 *     for them would be a second exit, and the point of this contract is that
 *     there is one.
 *
 * TOP UPS
 *   Anyone can transfer HCOW in. That is how a separately budgeted reward
 *   programme is added: the treasury sends it here and the keeper streams it
 *   with the same call. Once here it can only become staking rewards.
 */
contract HCOWRewardVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Shortest stream the keeper may open. HCOWStaking's own floor is
    ///         one day; a week matches Profit Share's epoch so a settlement's
    ///         share is never released faster than the epoch it came from.
    uint64 public constant MIN_DURATION = 7 days;
    /// @notice Longest stream. Deliberately far below HCOWStaking's year: see
    ///         WHAT IT CANNOT ENFORCE. A longer budgeted programme is streamed
    ///         in thirty day instalments.
    uint64 public constant MAX_DURATION = 30 days;

    IERC20 public immutable hcow;
    IHCOWStakingFunding public immutable staking;

    address public owner;
    address public pendingOwner;
    address public keeper;

    /// @notice HCOW handed to the staking stream through this vault, ever.
    uint256 public totalStreamed;

    event Streamed(address indexed keeper, uint256 amount, uint64 duration);
    event KeeperChanged(address indexed keeper);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed nominee);

    error NotOwner();
    error NotKeeper();
    error NotPendingOwner();
    error ZeroAddress();
    error WrongToken();
    error BadDuration(uint64 given);
    error InsufficientBalance(uint256 requested, uint256 available);
    error StreamMismatch(uint256 expected, uint256 moved);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address hcowToken, address stakingContract, address initialOwner, address initialKeeper) {
        if (
            hcowToken == address(0) || stakingContract == address(0) ||
            initialOwner == address(0) || initialKeeper == address(0)
        ) revert ZeroAddress();
        // The one exit has to lead to a staking contract that streams the same
        // token. Asked of the contract, not assumed from the argument order.
        if (address(IHCOWStakingFunding(stakingContract).hcow()) != hcowToken) revert WrongToken();
        hcow = IERC20(hcowToken);
        staking = IHCOWStakingFunding(stakingContract);
        owner = initialOwner;
        keeper = initialKeeper;
        emit OwnershipTransferred(address(0), initialOwner);
        emit KeeperChanged(initialKeeper);
    }

    /**
     * @notice Stream `amount` of the HCOW held here into staking rewards over
     *         `duration` seconds.
     * @dev amount may be zero, which HCOWStaking accepts only when it has a
     *      carried balance to release. That decision is left to it.
     */
    function fund(uint256 amount, uint64 duration) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration(duration);
        uint256 before = hcow.balanceOf(address(this));
        if (amount > before) revert InsufficientBalance(amount, before);

        // Effects first. A refused stream reverts the whole call, this included.
        totalStreamed += amount;
        emit Streamed(msg.sender, amount, duration);

        address to = address(staking);
        hcow.forceApprove(to, amount);
        staking.fundRewards(amount, duration);
        // Staking pulls exactly `amount`, so this is already zero against the
        // contract as written. It is cleared anyway so that no allowance can
        // outlive the call whatever the staking contract does.
        hcow.forceApprove(to, 0);

        // The one exit is checked rather than trusted: exactly `amount` left.
        uint256 moved = before - hcow.balanceOf(address(this));
        if (moved != amount) revert StreamMismatch(amount, moved);
    }

    /// @notice HCOW waiting here to be streamed.
    function balance() external view returns (uint256) {
        return hcow.balanceOf(address(this));
    }

    /// @notice Whether fund() can currently reach the stream at all.
    function isLive() external view returns (bool) {
        return staking.rewardFunder() == address(this);
    }

    // ------------------------------------------------------------------
    // administration. none of it can move HCOW.
    // ------------------------------------------------------------------

    function setKeeper(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        keeper = account;
        emit KeeperChanged(account);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        address was = pendingOwner;
        if (was == address(0)) revert ZeroAddress();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(was);
    }
}
