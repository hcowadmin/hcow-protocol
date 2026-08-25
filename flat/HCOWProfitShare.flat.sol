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


// File @openzeppelin/contracts/utils/ReentrancyGuard.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}


// File contracts/HCOWProfitShare.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.26;



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
