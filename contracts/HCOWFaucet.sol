// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
    /// @notice Nominated owner. Not the owner until it calls acceptOwnership.
    address public pendingOwner;

    /// @notice One claim per address per interval.
    uint64 public constant CLAIM_INTERVAL = 24 hours;

    /// @notice Claims the faucet will serve inside one interval, across every
    ///         address, unless the owner reopens it early with resetWindow().
    ///
    /// The per address cooldown bounds one address. It does not bound one
    /// person, because addresses are free: a contract that deploys a throwaway
    /// caller per allowance takes the entire faucet in a single transaction,
    /// and the per address cooldown is untouched by it. This is the only thing
    /// that makes the faucet drain slower than it can be refilled, which is
    /// what a public testnet campaign actually needs.
    uint256 public constant MAX_CLAIMS_PER_INTERVAL = 250;

    /// @notice Amounts handed out per claim. Owner adjustable as supply allows.
    uint256 public hcowAmount = 50_000e18;
    uint256 public usdtAmount = 1_000e18;

    mapping(address => uint64) public lastClaimAt;

    /// @notice When the current global interval opened, and how many claims
    ///         have been served inside it.
    uint64 public windowAt;
    uint256 public windowClaims;

    /// @notice Distinct addresses that have claimed at least once.
    uint256 public claimerCount;
    uint256 public totalClaims;

    event Claimed(address indexed account, uint256 hcowAmount, uint256 usdtAmount);
    event AmountsChanged(uint256 hcowAmount, uint256 usdtAmount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event WindowReset(uint64 at);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed nominee);

    error NotOwner();
    error ZeroAddress();
    error NotPendingOwner();
    error CooldownActive(uint64 readyAt);
    error FaucetEmpty(address token, uint256 requested, uint256 available);
    error SameToken();
    error ZeroAmounts();
    error ContractCaller();
    error FaucetRateLimited(uint64 readyAt);
    error NothingToReset();

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
        // A person claims from an address they control. A contract claiming is
        // always a batcher, and batching is the whole of the drain: one funding
        // transaction, one factory, and every allowance in the faucet gone in a
        // single block with no cooldown anywhere reporting it. Neither check is
        // sufficient alone: code.length is zero during a constructor, and
        // tx.origin equality is what closes deploy and claim in one call.
        //
        // This also excludes smart contract wallets, Safe and ERC-4337 alike,
        // and an EOA that has delegated code under EIP-7702. That is a real
        // cost and it is accepted here because this is a testnet faucet handing
        // out stand-in tokens: a tester who cannot claim can ask the team, and
        // a faucet that is empty helps nobody at all.
        //
        // EIP-7702 went live on BNB Chain on 20 March 2025 and it changed which
        // half of this line carries the weight. Before it, msg.sender ==
        // tx.origin was read as "the caller is an EOA". It is not that any
        // more: a delegated EOA is the origin of its own transaction and has
        // code, so the two are no longer equivalent and neither implies the
        // other. The pair still holds, because code.length rejects a delegated
        // EOA and tx.origin rejects a contract calling mid-constructor, but
        // the reasoning is now "an address with no code that sent its own
        // transaction", not "an EOA".
        //
        // These are the only two uses of tx.origin or code.length anywhere in
        // either repository, and this is the only function that has them. No
        // contract that moves real value depends on either.
        if (msg.sender != tx.origin || msg.sender.code.length != 0) revert ContractCaller();

        if (windowAt == 0 || block.timestamp >= windowAt + CLAIM_INTERVAL) {
            windowAt = uint64(block.timestamp);
            windowClaims = 0;
        }
        if (windowClaims >= MAX_CLAIMS_PER_INTERVAL) {
            revert FaucetRateLimited(windowAt + CLAIM_INTERVAL);
        }

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
            // Report whichever side is further from paying, measured as a
            // shortfall. Comparing raw balances of two different tokens names
            // the wrong one whenever the amounts differ.
            bool hcowWorse = (hcowAmount - hcowHeld) >= (usdtAmount - usdtHeld);
            revert FaucetEmpty(
                hcowWorse ? address(hcow) : address(usdt),
                hcowWorse ? hcowAmount : usdtAmount,
                hcowWorse ? hcowHeld : usdtHeld
            );
        }

        if (lastClaimAt[msg.sender] == 0) claimerCount += 1;
        // Always spent. Charging it only for a full allowance sounds fairer and
        // removes the cooldown entirely in the state the faucet actually lives
        // in: USDT drains far faster than HCOW, so "one side short" is the
        // steady state, and in that state one address can empty the other side
        // in a single block.
        lastClaimAt[msg.sender] = uint64(block.timestamp);
        totalClaims += 1;
        windowClaims += 1;

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
            uint256 claimsLeft,
            uint256 windowClaimsLeft,
            uint64 windowResetsAt,
            uint256 hcowNow,
            uint256 usdtNow
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

        // What this caller would ACTUALLY receive if they claimed right now,
        // computed the same way claim() computes it.
        //
        // claimsLeft below counts FULL allowances, and the two sides are paid
        // independently, so it reads zero while a claim would still succeed on
        // one side. An interface that disables the button on claimsLeft blocks
        // claims the contract would honour, and in the state this faucet
        // actually lives in, with USDT draining far faster than HCOW, that is
        // the steady state rather than an edge case. These two are what the UI
        // should show: a user about to spend their daily claim on a one-sided
        // payout can then see that is what they are doing and decide.
        hcowNow = hcowRemaining >= hcowAmount ? hcowAmount : 0;
        usdtNow = usdtRemaining >= usdtAmount ? usdtAmount : 0;
        if (readyAt != 0) { hcowNow = 0; usdtNow = 0; }

        // The binding constraint, so the UI can say "3 claims left" honestly.
        // A claim spends the cooldown whether or not both sides paid, so the
        // honest figure is how many FULL allowances are left.
        uint256 byHcow = hcowRemaining / hcowAmount;
        uint256 byUsdt = usdtRemaining / usdtAmount;
        claimsLeft = byHcow < byUsdt ? byHcow : byUsdt;

        // The global ceiling binds before the balances do once it is reached,
        // and a UI that cannot see it disables nothing and lets the user sign
        // a transaction that reverts, which is the exact failure this function
        // exists to prevent.
        bool fresh = windowAt == 0 || block.timestamp >= windowAt + CLAIM_INTERVAL;
        uint256 used = fresh ? 0 : windowClaims;
        windowClaimsLeft = used >= MAX_CLAIMS_PER_INTERVAL
            ? 0
            : MAX_CLAIMS_PER_INTERVAL - used;
        windowResetsAt = fresh ? 0 : windowAt + CLAIM_INTERVAL;
        if (windowClaimsLeft < claimsLeft) claimsLeft = windowClaimsLeft;
        if (windowClaimsLeft == 0) { hcowNow = 0; usdtNow = 0; }
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

    /**
     * @notice Reopen the global claim ceiling before its interval is up.
     *
     * @dev Addresses are free, so the ceiling can be spent by throwaway EOAs
     *      as easily as by testers. Without this, refilling the faucet does
     *      not restore service and the campaign is dead until the interval
     *      rolls, which hands a cheap denial of service to anyone who wants
     *      one. Testnet contract, owner-only, nothing of value behind it.
     */
    function resetWindow() external onlyOwner {
        if (windowClaims == 0) revert NothingToReset();
        windowAt = uint64(block.timestamp);
        windowClaims = 0;
        emit WindowReset(uint64(block.timestamp));
    }

    /// @notice Recover anything sent here, including tokens sent by mistake.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /**
     * @notice Step one of two. The nominee is not the owner until it accepts.
     *
     * @dev Testnet only, so a lost owner key costs nothing of value: claims
     *      keep working until the balance runs out and the remainder is then
     *      unrecoverable. Two steps here is consistency with the sibling
     *      contracts rather than a risk judgement, and consistency is worth
     *      something on its own: this is the contract a reader meets first.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step two of two, called by the nominee.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Withdraw a standing nomination.
    function cancelOwnershipTransfer() external onlyOwner {
        address was = pendingOwner;
        if (was == address(0)) revert ZeroAddress();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(was);
    }
}
