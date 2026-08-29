// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {StakingInvariants} from "../Staking.invariant.t.sol";

/**
 * @title MedusaStaking
 * @notice The staking properties under the second engine.
 *
 * Same rule as MedusaProfitShare: nothing is restated. Every property_
 * delegates to the invariant_ of the same name so the two engines cannot drift
 * apart, and a failure means the same thing in both.
 */
contract MedusaStaking is StakingInvariants {
    constructor() {
        setUp();
    }

    function stake(uint256 a, uint256 b, uint256 c) external { handler.stake(a, b, c); }
    function redelegate(uint256 a, uint256 b) external { handler.redelegate(a, b); }
    function requestUnstake(uint256 a, uint256 b) external { handler.requestUnstake(a, b); }
    function cancelUnstake(uint256 a) external { handler.cancelUnstake(a); }
    function withdrawUnstaked(uint256 a) external { handler.withdrawUnstaked(a); }
    function claimHcow(uint256 a) external { handler.claimHcow(a); }
    function claimCommission(uint256 a) external { handler.claimCommission(a); }
    function updateRep(uint256 a, uint256 b, uint256 c) external { handler.updateRep(a, b, c); }
    function warp(uint256 s) external { handler.warp(s); }
    function fund(uint256 a, uint256 d) external { handler.fund(a, d); }

    function _held(function() external view f) private view returns (bool) {
        try f() { return true; } catch { return false; }
    }

    function property_fundingNeverSlowsTheStream() public view returns (bool) {
        return _held(this.invariant_fundingNeverSlowsTheStream);
    }
    function property_fundingNeverPullsTheEndDateIn() public view returns (bool) {
        return _held(this.invariant_fundingNeverPullsTheEndDateIn);
    }
    function property_hcowBacked() public view returns (bool) {
        return _held(this.invariant_hcowBacked);
    }
    function property_noRewardCreation() public view returns (bool) {
        return _held(this.invariant_noRewardCreation);
    }
    function property_stakeConservation() public view returns (bool) {
        return _held(this.invariant_stakeConservation);
    }
    function property_repWeightConservation() public view returns (bool) {
        return _held(this.invariant_repWeightConservation);
    }
    function property_pendingConservation() public view returns (bool) {
        return _held(this.invariant_pendingConservation);
    }
    function property_periodFinishNotInThePast() public view returns (bool) {
        return _held(this.invariant_periodFinishNotInThePast);
    }
}
