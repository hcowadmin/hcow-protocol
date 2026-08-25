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


// File @openzeppelin/contracts/utils/math/SafeCast.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/SafeCast.sol)
// This file was procedurally generated from scripts/generate/templates/SafeCast.js.

pragma solidity ^0.8.20;

/**
 * @dev Wrappers over Solidity's uintXX/intXX casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeCast {
    /**
     * @dev Value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /**
     * @dev An int value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedIntToUint(int256 value);

    /**
     * @dev Value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);

    /**
     * @dev An uint value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedUintToInt(uint256 value);

    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        if (value > type(uint248).max) {
            revert SafeCastOverflowedUintDowncast(248, value);
        }
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        if (value > type(uint240).max) {
            revert SafeCastOverflowedUintDowncast(240, value);
        }
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        if (value > type(uint232).max) {
            revert SafeCastOverflowedUintDowncast(232, value);
        }
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        if (value > type(uint224).max) {
            revert SafeCastOverflowedUintDowncast(224, value);
        }
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        if (value > type(uint216).max) {
            revert SafeCastOverflowedUintDowncast(216, value);
        }
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        if (value > type(uint208).max) {
            revert SafeCastOverflowedUintDowncast(208, value);
        }
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        if (value > type(uint200).max) {
            revert SafeCastOverflowedUintDowncast(200, value);
        }
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        if (value > type(uint192).max) {
            revert SafeCastOverflowedUintDowncast(192, value);
        }
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        if (value > type(uint184).max) {
            revert SafeCastOverflowedUintDowncast(184, value);
        }
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        if (value > type(uint176).max) {
            revert SafeCastOverflowedUintDowncast(176, value);
        }
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        if (value > type(uint168).max) {
            revert SafeCastOverflowedUintDowncast(168, value);
        }
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        if (value > type(uint160).max) {
            revert SafeCastOverflowedUintDowncast(160, value);
        }
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        if (value > type(uint152).max) {
            revert SafeCastOverflowedUintDowncast(152, value);
        }
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        if (value > type(uint144).max) {
            revert SafeCastOverflowedUintDowncast(144, value);
        }
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        if (value > type(uint136).max) {
            revert SafeCastOverflowedUintDowncast(136, value);
        }
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            revert SafeCastOverflowedUintDowncast(128, value);
        }
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        if (value > type(uint120).max) {
            revert SafeCastOverflowedUintDowncast(120, value);
        }
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        if (value > type(uint112).max) {
            revert SafeCastOverflowedUintDowncast(112, value);
        }
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        if (value > type(uint104).max) {
            revert SafeCastOverflowedUintDowncast(104, value);
        }
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        if (value > type(uint96).max) {
            revert SafeCastOverflowedUintDowncast(96, value);
        }
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        if (value > type(uint88).max) {
            revert SafeCastOverflowedUintDowncast(88, value);
        }
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        if (value > type(uint80).max) {
            revert SafeCastOverflowedUintDowncast(80, value);
        }
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        if (value > type(uint72).max) {
            revert SafeCastOverflowedUintDowncast(72, value);
        }
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) {
            revert SafeCastOverflowedUintDowncast(64, value);
        }
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        if (value > type(uint56).max) {
            revert SafeCastOverflowedUintDowncast(56, value);
        }
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        if (value > type(uint48).max) {
            revert SafeCastOverflowedUintDowncast(48, value);
        }
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        if (value > type(uint40).max) {
            revert SafeCastOverflowedUintDowncast(40, value);
        }
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) {
            revert SafeCastOverflowedUintDowncast(32, value);
        }
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        if (value > type(uint24).max) {
            revert SafeCastOverflowedUintDowncast(24, value);
        }
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) {
            revert SafeCastOverflowedUintDowncast(16, value);
        }
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        if (value > type(uint8).max) {
            revert SafeCastOverflowedUintDowncast(8, value);
        }
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        if (value < 0) {
            revert SafeCastOverflowedIntToUint(value);
        }
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toInt248(int256 value) internal pure returns (int248 downcasted) {
        downcasted = int248(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(248, value);
        }
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toInt240(int256 value) internal pure returns (int240 downcasted) {
        downcasted = int240(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(240, value);
        }
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toInt232(int256 value) internal pure returns (int232 downcasted) {
        downcasted = int232(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(232, value);
        }
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toInt224(int256 value) internal pure returns (int224 downcasted) {
        downcasted = int224(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(224, value);
        }
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toInt216(int256 value) internal pure returns (int216 downcasted) {
        downcasted = int216(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(216, value);
        }
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toInt208(int256 value) internal pure returns (int208 downcasted) {
        downcasted = int208(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(208, value);
        }
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toInt200(int256 value) internal pure returns (int200 downcasted) {
        downcasted = int200(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(200, value);
        }
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toInt192(int256 value) internal pure returns (int192 downcasted) {
        downcasted = int192(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(192, value);
        }
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toInt184(int256 value) internal pure returns (int184 downcasted) {
        downcasted = int184(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(184, value);
        }
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toInt176(int256 value) internal pure returns (int176 downcasted) {
        downcasted = int176(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(176, value);
        }
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toInt168(int256 value) internal pure returns (int168 downcasted) {
        downcasted = int168(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(168, value);
        }
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toInt160(int256 value) internal pure returns (int160 downcasted) {
        downcasted = int160(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(160, value);
        }
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toInt152(int256 value) internal pure returns (int152 downcasted) {
        downcasted = int152(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(152, value);
        }
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toInt144(int256 value) internal pure returns (int144 downcasted) {
        downcasted = int144(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(144, value);
        }
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toInt136(int256 value) internal pure returns (int136 downcasted) {
        downcasted = int136(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(136, value);
        }
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toInt128(int256 value) internal pure returns (int128 downcasted) {
        downcasted = int128(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(128, value);
        }
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toInt120(int256 value) internal pure returns (int120 downcasted) {
        downcasted = int120(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(120, value);
        }
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toInt112(int256 value) internal pure returns (int112 downcasted) {
        downcasted = int112(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(112, value);
        }
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toInt104(int256 value) internal pure returns (int104 downcasted) {
        downcasted = int104(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(104, value);
        }
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toInt96(int256 value) internal pure returns (int96 downcasted) {
        downcasted = int96(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(96, value);
        }
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toInt88(int256 value) internal pure returns (int88 downcasted) {
        downcasted = int88(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(88, value);
        }
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toInt80(int256 value) internal pure returns (int80 downcasted) {
        downcasted = int80(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(80, value);
        }
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toInt72(int256 value) internal pure returns (int72 downcasted) {
        downcasted = int72(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(72, value);
        }
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toInt64(int256 value) internal pure returns (int64 downcasted) {
        downcasted = int64(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(64, value);
        }
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toInt56(int256 value) internal pure returns (int56 downcasted) {
        downcasted = int56(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(56, value);
        }
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toInt48(int256 value) internal pure returns (int48 downcasted) {
        downcasted = int48(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(48, value);
        }
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toInt40(int256 value) internal pure returns (int40 downcasted) {
        downcasted = int40(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(40, value);
        }
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toInt32(int256 value) internal pure returns (int32 downcasted) {
        downcasted = int32(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(32, value);
        }
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toInt24(int256 value) internal pure returns (int24 downcasted) {
        downcasted = int24(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(24, value);
        }
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toInt16(int256 value) internal pure returns (int16 downcasted) {
        downcasted = int16(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(16, value);
        }
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toInt8(int256 value) internal pure returns (int8 downcasted) {
        downcasted = int8(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(8, value);
        }
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert SafeCastOverflowedUintToInt(value);
        }
        return int256(value);
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


// File contracts/HCOWStaking.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.26;




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
    using SafeCast for uint256;

    /// @notice Hard ceiling on representative commission. 10%.
    uint16 public constant MAX_COMMISSION_BPS = 1000;

    /**
     * @notice Ceiling on registered representatives.
     *
     * fundRewards loops the whole list twice, so every registration makes every
     * future funding round permanently more expensive. Without a ceiling a
     * careless or hostile owner can push that loop past the block gas limit on
     * a contract that cannot be upgraded, and no reward could ever be paid
     * again. Deregistration is not offered because a representative with live
     * delegations cannot safely disappear.
     */
    uint256 public constant MAX_REPRESENTATIVES = 100;

    /// @notice Wait between requesting an unstake and being able to withdraw.
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    uint256 private constant ACC_PRECISION = 1e18;

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
        uint256 rewardDebtGross;  // bookmark on the global accumulator
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
    event Staked(address indexed account, bytes32 indexed repId, uint256 amount);
    event Redelegated(address indexed account, bytes32 indexed fromRep, bytes32 indexed toRep, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt);
    event UnstakeCancelled(address indexed account, uint256 amount);
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
        _updateGlobal();
        r.accNetAnchor = accRewardPerShare;
        r.commAnchor = accRewardPerShare;
        if (_repIds.length >= MAX_REPRESENTATIVES) {
            revert TooManyRepresentatives(MAX_REPRESENTATIVES);
        }
        _repIds.push(id);

        emit RepresentativeRegistered(id, name, payout, commissionBps, isFoundation);
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
            _rewardsOwed -= owed;
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

        if (d.amount == 0) r.delegatorCount -= 1;

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

        _harvest(d);
        _accrueRepCommission(r);

        uint256 amount = d.pendingUnstake;
        d.pendingUnstake = 0;
        d.unstakeReadyAt = 0;
        totalPendingUnstake -= amount;

        if (d.amount == 0) r.delegatorCount += 1;
        d.amount += amount.toUint128();
        r.totalDelegated += amount;
        totalStaked += amount;

        _bookmark(d, r);
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
        _rewardsOwed -= amount;

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
        _rewardsOwed -= amount;

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
    function fundRewards(uint256 amount, uint64 duration) external nonReentrant {
        if (msg.sender != rewardFunder) revert NotFunder();
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_REWARD_DURATION || duration > MAX_REWARD_DURATION) {
            revert BadDuration(duration);
        }

        _updateGlobal();

        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        // Whatever the running period has not released yet, plus anything that
        // elapsed while nothing was staked, rolls into the new one. Funding
        // early therefore stretches the budget rather than discarding it.
        uint256 leftover = block.timestamp < periodFinish
            ? (uint256(periodFinish) - block.timestamp) * rewardRate
            : 0;
        uint256 pool = received + leftover + undistributed;
        undistributed = 0;

        rewardRate = pool / duration;
        if (rewardRate == 0) revert ZeroAmount();
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
        if (t > lastUpdateTime && totalStaked > 0) {
            acc += ((uint256(t - lastUpdateTime) * rewardRate) * ACC_PRECISION) / totalStaked;
        }

        Representative storage r = _reps[d.repId];
        uint256 netAcc = r.accNetBase
            + ((acc - r.accNetAnchor) * (10_000 - r.commissionBps)) / 10_000;
        uint256 net = (uint256(d.amount) * netAcc) / ACC_PRECISION;
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
            if (totalStaked > 0) {
                accRewardPerShare += (released * ACC_PRECISION) / totalStaked;
                _rewardsOwed += released;
            } else {
                // Nobody was owed these seconds. Carry them rather than either
                // stranding them or handing the whole window to whoever stakes
                // next, which would be the lump sum problem again.
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
            uint256 earned =
                (r.totalDelegated * delta * r.commissionBps) / (10_000 * ACC_PRECISION);
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
     */
    function totalRewardsOwed() public view returns (uint256) {
        uint256 owed = _rewardsOwed;
        uint64 t = uint64(block.timestamp) < periodFinish
            ? uint64(block.timestamp)
            : periodFinish;
        if (t > lastUpdateTime && totalStaked > 0) {
            owed += uint256(t - lastUpdateTime) * rewardRate;
        }
        return owed;
    }

    /// @notice Commission a representative could claim right now.
    function commissionOf(bytes32 id) external view returns (uint256) {
        Representative storage r = _reps[id];
        uint256 acc = accRewardPerShare;
        uint64 t = uint64(block.timestamp) < periodFinish
            ? uint64(block.timestamp)
            : periodFinish;
        if (t > lastUpdateTime && totalStaked > 0) {
            acc += ((uint256(t - lastUpdateTime) * rewardRate) * ACC_PRECISION) / totalStaked;
        }
        uint256 delta = acc - r.commAnchor;
        uint256 pending = (delta > 0 && r.totalDelegated > 0 && r.commissionBps > 0)
            ? (r.totalDelegated * delta * r.commissionBps) / (10_000 * ACC_PRECISION)
            : 0;
        return r.commissionAccrued + pending;
    }

    function _bookmark(Delegation storage d, Representative storage r) private {
        uint256 amt = uint256(d.amount);
        d.rewardDebtGross = (amt * accRewardPerShare) / ACC_PRECISION;
        d.rewardDebtNet = (amt * _netAcc(r)) / ACC_PRECISION;
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
            uint256 gross = (amt * accRewardPerShare) / ACC_PRECISION;
            uint256 net = (amt * _netAcc(r)) / ACC_PRECISION;
            uint256 netDelta = net > d.rewardDebtNet ? net - d.rewardDebtNet : 0;
            if (netDelta > 0) {
                d.claimable += netDelta;
                r.lifetimeRewards += netDelta;
            }
            // Commission is deliberately not taken here. It is an aggregate
            // over the representative's whole weight, folded in by
            // _accrueRepCommission, so a representative is paid without having
            // to wait for every delegator to touch their position.
            d.rewardDebtGross = gross;
            d.rewardDebtNet = net;
        } else {
            d.rewardDebtGross = 0;
            d.rewardDebtNet = 0;
        }
    }
}
