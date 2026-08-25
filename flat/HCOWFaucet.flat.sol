// Sources flattened with hardhat v2.29.0 https://hardhat.org

// SPDX-License-Identifier: MIT

// File @openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/IERC20Permit.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 *
 * ==== Security Considerations
 *
 * There are two important considerations concerning the use of `permit`. The first is that a valid permit signature
 * expresses an allowance, and it should not be assumed to convey additional meaning. In particular, it should not be
 * considered as an intention to spend the allowance in any specific way. The second is that because permits have
 * built-in replay protection and can be submitted by anyone, they can be frontrun. A protocol that uses permits should
 * take this into consideration and allow a `permit` call to fail. Combining these two aspects, a pattern that may be
 * generally recommended is:
 *
 * ```solidity
 * function doThingWithPermit(..., uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
 *     try token.permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
 *     doThing(..., value);
 * }
 *
 * function doThing(..., uint256 value) public {
 *     token.safeTransferFrom(msg.sender, address(this), value);
 *     ...
 * }
 * ```
 *
 * Observe that: 1) `msg.sender` is used as the owner, leaving no ambiguity as to the signer intent, and 2) the use of
 * `try/catch` allows the permit to fail and makes the code tolerant to frontrunning. (See also
 * {SafeERC20-safeTransferFrom}).
 *
 * Additionally, note that smart contract wallets (such as Argent or Safe) are not able to produce permit signatures, so
 * contracts should have entry points that don't rely on permit.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     *
     * CAUTION: See Security Considerations above.
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}


// File @openzeppelin/contracts/token/ERC20/IERC20.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}


// File @openzeppelin/contracts/utils/Address.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/Address.sol)

pragma solidity ^0.8.20;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error AddressInsufficientBalance(address account);

    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedInnerCall();

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert AddressInsufficientBalance(address(this));
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert FailedInnerCall();
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {FailedInnerCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert AddressInsufficientBalance(address(this));
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {FailedInnerCall}) in case of an
     * unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {FailedInnerCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {FailedInnerCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert FailedInnerCall();
        }
    }
}


// File @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/utils/SafeERC20.sol)

pragma solidity ^0.8.20;



/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    /**
     * @dev An operation with an ERC20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data);
        if (returndata.length != 0 && !abi.decode(returndata, (bool))) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silents catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return success && (returndata.length == 0 || abi.decode(returndata, (bool))) && address(token).code.length > 0;
    }
}


// File contracts/HCOWFaucet.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.26;


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

    error NotOwner();
    error ZeroAddress();
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
            uint64 windowResetsAt
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

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
