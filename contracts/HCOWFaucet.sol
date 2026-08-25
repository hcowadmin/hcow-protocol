// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title HCOWFaucet
 * @notice Hands out test HCOW and test USDT on BSC testnet, one claim per
 *         address per day, so a person can actually try bonding and claiming
 *         rather than only looking at a dashboard.
 *
 * TESTNET ONLY. It dispenses the stand-in tokens, which have no value. Nothing
 * about this contract should ever be deployed alongside the real HCOW token,
 * and there is deliberately no mint path: the faucet can only give away what
 * was put into it, so a bug here cannot inflate anything.
 *
 * It does not dispense gas. Calling `claim` already requires gas, so a faucet
 * that paid for gas could never be reached by the person who needs it. Testers
 * get their first tBNB from the public BNB Chain faucet or from the team.
 */
contract HCOWFaucet {
    using SafeERC20 for IERC20;

    IERC20 public immutable hcow;
    IERC20 public immutable usdt;

    address public owner;

    /// @notice One claim per address per interval.
    uint64 public constant CLAIM_INTERVAL = 24 hours;

    /// @notice Amounts handed out per claim. Owner adjustable as supply allows.
    uint256 public hcowAmount = 50_000e18;
    uint256 public usdtAmount = 1_000e18;

    mapping(address => uint64) public lastClaimAt;

    /// @notice Distinct addresses that have claimed at least once.
    uint256 public claimerCount;
    uint256 public totalClaims;

    event Claimed(address indexed account, uint256 hcowAmount, uint256 usdtAmount);
    event AmountsChanged(uint256 hcowAmount, uint256 usdtAmount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroAddress();
    error CooldownActive(uint64 readyAt);
    error FaucetEmpty(address token, uint256 requested, uint256 available);
    error SameToken();
    error ZeroAmounts();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address hcowToken, address usdtToken, address initialOwner) {
        if (hcowToken == address(0) || usdtToken == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        // One address for both tokens double counts the balance in `status`
        // and then reverts halfway through `claim`, leaving the faucet dead
        // with no way back. Cheaper to refuse the deployment.
        if (hcowToken == usdtToken) revert SameToken();
        hcow = IERC20(hcowToken);
        usdt = IERC20(usdtToken);
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /**
     * @notice Take one allowance of test tokens.
     * @dev No reentrancy guard is needed: the only external calls are the two
     *      token transfers, and both happen after every state change. The test
     *      tokens are plain OpenZeppelin ERC20s with no hooks, and even a
     *      hostile token could not claim twice because lastClaimAt is already
     *      written by then.
     */
    function claim() external {
        uint64 readyAt = lastClaimAt[msg.sender] + CLAIM_INTERVAL;
        if (lastClaimAt[msg.sender] != 0 && block.timestamp < readyAt) {
            revert CooldownActive(readyAt);
        }

        // Per token, not both or nothing. USDT drains far faster than HCOW at
        // any sensible ratio, so requiring both would leave the HCOW side
        // stranded and the faucet useless for its main purpose, in what is
        // the expected steady state rather than an edge case.
        uint256 hcowHeld = hcow.balanceOf(address(this));
        uint256 usdtHeld = usdt.balanceOf(address(this));
        uint256 hcowOut = hcowHeld >= hcowAmount ? hcowAmount : 0;
        uint256 usdtOut = usdtHeld >= usdtAmount ? usdtAmount : 0;
        if (hcowOut == 0 && usdtOut == 0) {
            revert FaucetEmpty(address(hcow), hcowAmount, hcowHeld);
        }

        if (lastClaimAt[msg.sender] == 0) claimerCount += 1;
        lastClaimAt[msg.sender] = uint64(block.timestamp);
        totalClaims += 1;

        if (hcowOut > 0) hcow.safeTransfer(msg.sender, hcowOut);
        if (usdtOut > 0) usdt.safeTransfer(msg.sender, usdtOut);

        emit Claimed(msg.sender, hcowOut, usdtOut);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    /// @notice Unix seconds when `account` may claim again. 0 means now.
    function claimableAt(address account) external view returns (uint64) {
        uint64 last = lastClaimAt[account];
        if (last == 0) return 0;
        uint64 readyAt = last + CLAIM_INTERVAL;
        return block.timestamp >= readyAt ? 0 : readyAt;
    }

    /**
     * @notice Everything the UI needs in one call, so a button can be disabled
     *         with a reason rather than failing after the user signs.
     */
    function status(address account)
        external
        view
        returns (
            uint256 hcowPerClaim,
            uint256 usdtPerClaim,
            uint256 hcowRemaining,
            uint256 usdtRemaining,
            uint64 readyAt,
            uint256 claimsLeft
        )
    {
        hcowPerClaim = hcowAmount;
        usdtPerClaim = usdtAmount;
        hcowRemaining = hcow.balanceOf(address(this));
        usdtRemaining = usdt.balanceOf(address(this));

        uint64 last = lastClaimAt[account];
        if (last != 0 && block.timestamp < last + CLAIM_INTERVAL) {
            readyAt = last + CLAIM_INTERVAL;
        }

        // The binding constraint, so the UI can say "3 claims left" honestly.
        // Both amounts are non-zero by construction, so there is no infinite
        // branch to report.
        uint256 byHcow = hcowRemaining / hcowAmount;
        uint256 byUsdt = usdtRemaining / usdtAmount;
        claimsLeft = byHcow < byUsdt ? byHcow : byUsdt;
    }

    // ------------------------------------------------------------------
    // administration
    // ------------------------------------------------------------------

    function setAmounts(uint256 newHcowAmount, uint256 newUsdtAmount) external onlyOwner {
        // Zero would let claim() succeed, pay nothing, and still burn the
        // caller's 24 hour cooldown, while status() reported an infinite
        // number of claims left.
        if (newHcowAmount == 0 || newUsdtAmount == 0) revert ZeroAmounts();
        hcowAmount = newHcowAmount;
        usdtAmount = newUsdtAmount;
        emit AmountsChanged(newHcowAmount, newUsdtAmount);
    }

    /// @notice Recover anything sent here, including tokens sent by mistake.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
