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

    /// @notice Hard ceiling on representative commission. 10%.
    uint16 public constant MAX_COMMISSION_BPS = 1000;

    /// @notice Wait between requesting an unstake and being able to withdraw.
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    uint256 private constant ACC_PRECISION = 1e18;

    IERC20 public immutable hcow;

    address public owner;
    address public rewardFunder;

    struct Representative {
        address payout;            // receives commission
        uint16  commissionBps;     // <= MAX_COMMISSION_BPS
        bool    active;            // inactive reps receive no new rewards
        bool    isFoundation;
        bool    exists;
        uint256 totalDelegated;
        uint256 delegatorCount;
        uint256 accRewardPerShare;
        uint256 commissionAccrued;
        uint256 lifetimeRewards;   // delegator rewards routed through this rep
        string  name;
    }

    struct Delegation {
        bytes32 repId;
        uint128 amount;
        uint128 pendingUnstake;
        uint64  unstakeReadyAt;
        uint256 rewardDebt;
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
    /// @notice HCOW held to pay accrued delegator rewards and commission.
    uint256 public totalRewardsOwed;
    uint256 public totalRewardsFunded;

    event RepresentativeRegistered(bytes32 indexed id, string name, address payout, uint16 commissionBps, bool isFoundation);
    event RepresentativeUpdated(bytes32 indexed id, address payout, uint16 commissionBps, bool active);
    event Staked(address indexed account, bytes32 indexed repId, uint256 amount);
    event Redelegated(address indexed account, bytes32 indexed fromRep, bytes32 indexed toRep, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt);
    event UnstakeCancelled(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event CommissionClaimed(bytes32 indexed repId, address indexed payout, uint256 amount);
    event RewardsFunded(uint256 amount, uint256 activeWeight, uint256 activeReps);
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
    error NoActiveWeight();
    error SameRepresentative();

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
        _repIds.push(id);

        emit RepresentativeRegistered(id, name, payout, commissionBps, isFoundation);
    }

    function updateRepresentative(bytes32 id, address payout, uint16 commissionBps, bool active)
        external
        onlyOwner
    {
        Representative storage r = _reps[id];
        if (!r.exists) revert UnknownRepresentative(id);
        if (payout == address(0)) revert ZeroAddress();
        if (commissionBps > MAX_COMMISSION_BPS) {
            revert CommissionTooHigh(commissionBps, MAX_COMMISSION_BPS);
        }
        r.payout = payout;
        r.commissionBps = commissionBps;
        r.active = active;
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

        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        if (d.amount == 0) {
            d.repId = repId;
            r.delegatorCount += 1;
        }
        d.amount += uint128(received);
        r.totalDelegated += received;
        totalStaked += received;

        d.rewardDebt = (uint256(d.amount) * r.accRewardPerShare) / ACC_PRECISION;
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
        uint256 amount = d.amount;
        from.totalDelegated -= amount;
        from.delegatorCount -= 1;

        d.repId = toRepId;
        to.totalDelegated += amount;
        to.delegatorCount += 1;
        d.rewardDebt = (amount * to.accRewardPerShare) / ACC_PRECISION;

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
        d.amount -= uint128(amount);
        r.totalDelegated -= amount;
        totalStaked -= amount;

        if (d.amount == 0) r.delegatorCount -= 1;

        d.pendingUnstake = uint128(amount);
        d.unstakeReadyAt = uint64(block.timestamp + UNSTAKE_COOLDOWN);
        totalPendingUnstake += amount;

        d.rewardDebt = (uint256(d.amount) * r.accRewardPerShare) / ACC_PRECISION;
        emit UnstakeRequested(msg.sender, amount, d.unstakeReadyAt);
    }

    function cancelUnstake() external nonReentrant {
        Delegation storage d = _delegations[msg.sender];
        if (d.unstakeReadyAt == 0) revert NoPendingUnstake();

        Representative storage r = _reps[d.repId];
        if (!r.active) revert RepresentativeInactive(d.repId);

        _harvest(d);

        uint256 amount = d.pendingUnstake;
        d.pendingUnstake = 0;
        d.unstakeReadyAt = 0;
        totalPendingUnstake -= amount;

        if (d.amount == 0) r.delegatorCount += 1;
        d.amount += uint128(amount);
        r.totalDelegated += amount;
        totalStaked += amount;

        d.rewardDebt = (uint256(d.amount) * r.accRewardPerShare) / ACC_PRECISION;
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
        totalRewardsOwed -= amount;

        hcow.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Anyone may trigger a payout, but it only ever goes to the
    ///         representative's registered payout address.
    function claimCommission(bytes32 repId) external nonReentrant {
        Representative storage r = _reps[repId];
        if (!r.exists) revert UnknownRepresentative(repId);

        uint256 amount = r.commissionAccrued;
        if (amount == 0) revert NothingToClaim();
        r.commissionAccrued = 0;
        totalRewardsOwed -= amount;

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
    function fundRewards(uint256 amount) external nonReentrant {
        if (msg.sender != rewardFunder) revert NotFunder();
        if (amount == 0) revert ZeroAmount();

        uint256 activeWeight;
        uint256 activeCount;
        uint256 n = _repIds.length;
        for (uint256 i = 0; i < n; ++i) {
            Representative storage r = _reps[_repIds[i]];
            if (r.active && r.totalDelegated > 0) {
                activeWeight += r.totalDelegated;
                activeCount += 1;
            }
        }
        if (activeWeight == 0) revert NoActiveWeight();

        uint256 before = hcow.balanceOf(address(this));
        hcow.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hcow.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        uint256 handedOut;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 id = _repIds[i];
            Representative storage r = _reps[id];
            if (!r.active || r.totalDelegated == 0) continue;

            uint256 slice = (received * r.totalDelegated) / activeWeight;
            if (slice == 0) continue;
            handedOut += slice;

            uint256 commission = (slice * r.commissionBps) / 10_000;
            uint256 toDelegators = slice - commission;

            r.commissionAccrued += commission;
            r.accRewardPerShare += (toDelegators * ACC_PRECISION) / r.totalDelegated;
            r.lifetimeRewards += toDelegators;
        }

        // Rounding dust stays in the contract and is picked up by the next
        // round, rather than being stranded or silently pocketed.
        totalRewardsOwed += handedOut;
        totalRewardsFunded += received;

        emit RewardsFunded(received, activeWeight, activeCount);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function pendingRewardOf(address account) public view returns (uint256) {
        Delegation storage d = _delegations[account];
        if (d.amount == 0) return d.claimable;
        uint256 accrued = (uint256(d.amount) * _reps[d.repId].accRewardPerShare) / ACC_PRECISION;
        return d.claimable + (accrued > d.rewardDebt ? accrued - d.rewardDebt : 0);
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

    function _harvest(Delegation storage d) private {
        if (d.amount > 0) {
            uint256 accrued = (uint256(d.amount) * _reps[d.repId].accRewardPerShare) / ACC_PRECISION;
            if (accrued > d.rewardDebt) {
                d.claimable += accrued - d.rewardDebt;
            }
            d.rewardDebt = accrued;
        }
    }
}
