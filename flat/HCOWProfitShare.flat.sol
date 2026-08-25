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


// File @openzeppelin/contracts/utils/math/Math.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/Math.sol)

pragma solidity ^0.8.20;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Muldiv operation overflow.
     */
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            return a / b;
        }

        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (unsignedRoundsUp(rounding) && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (unsignedRoundsUp(rounding) && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (unsignedRoundsUp(rounding) && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (unsignedRoundsUp(rounding) && 1 << (result << 3) < value ? 1 : 0);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
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


// File contracts/HCOWProfitShare.sol

// Original license: SPDX_License_Identifier: MIT
pragma solidity ^0.8.26;





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
