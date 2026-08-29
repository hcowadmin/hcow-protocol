// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ProfitShareInvariants} from "../ProfitShare.invariant.t.sol";

/**
 * @title MedusaProfitShare
 * @notice The same properties, searched by a different engine.
 *
 * Foundry's invariant runner and Medusa are both coverage-guided, but they
 * schedule differently: Foundry draws a fresh sequence per run and reverts the
 * chain between runs, Medusa keeps a corpus, mutates sequences that reached new
 * code, and carries block time forward across a much longer campaign. A
 * property that Foundry's scheduler never reaches in 128 calls is not a
 * property that holds, it is a property nobody has tested, and this session's
 * whole finding is that suites written by the author of the fix agree with the
 * fix.
 *
 * The properties are NOT restated here. Every property_ function below
 * delegates to the invariant_ function of the same name in
 * ProfitShareInvariants and reports a revert as a failure. Restating them would
 * create exactly the drift that let ghostRule6Breaches copy the contract's own
 * flawed definition of Rule 6 and agree with it.
 *
 * Run: medusa fuzz --config medusa.json
 */
contract MedusaProfitShare is ProfitShareInvariants {
    constructor() {
        // Medusa runs the constructor at deployment. setUp() is Foundry's
        // entry point and is reused verbatim so the two engines start from an
        // identical world.
        setUp();
    }

    // ---------------------------------------------------------- the actions
    //
    // Medusa calls the external functions of the target contract, so the
    // handler's actions are forwarded rather than targeted directly. The
    // handler is the same instance the Foundry runner drives, ghost counters
    // included, so both engines feed the same bookkeeping.

    function bond(uint256 a, uint256 b) external { handler.bond(a, b); }
    function requestUnbond(uint256 a, uint256 b) external { handler.requestUnbond(a, b); }
    function cancelUnbond(uint256 a) external { handler.cancelUnbond(a); }
    function withdrawUnbonded(uint256 a) external { handler.withdrawUnbonded(a); }
    function claimUsdt(uint256 a) external { handler.claimUsdt(a); }
    function warp(uint256 s) external { handler.warp(s); }
    function settle(uint256 g, uint256 c, uint256 o, uint256 p) external { handler.settle(g, c, o, p); }
    function settleWithSandwich(uint256 g, uint256 a) external { handler.settleWithSandwich(g, a); }
    function settleRunbook(uint256 g, uint256 p) external { handler.settleRunbook(g, p); }
    function settleRunbookFullCycle(uint256 a, uint256 g) external { handler.settleRunbookFullCycle(a, g); }
    function closeStalled() external { handler.closeStalled(); }

    // ------------------------------------------------------- the properties

    function _held(function() external view f) private view returns (bool) {
        try f() { return true; } catch { return false; }
    }

    function property_priceNeverFallsOutsideSettlement() public view returns (bool) {
        return _held(this.invariant_priceNeverFallsOutsideSettlement);
    }
    function property_hcowBacked() public view returns (bool) {
        return _held(this.invariant_hcowBacked);
    }
    function property_usdtSolvent() public view returns (bool) {
        return _held(this.invariant_usdtSolvent);
    }
    function property_burnAccounted() public view returns (bool) {
        return _held(this.invariant_burnAccounted);
    }
    function property_shareConservation() public view returns (bool) {
        return _held(this.invariant_shareConservation);
    }
    function property_pendingConservation() public view returns (bool) {
        return _held(this.invariant_pendingConservation);
    }
    function property_newSharesBounded() public view returns (bool) {
        return _held(this.invariant_newSharesBounded);
    }
    function property_noSharesNoPrincipal() public view returns (bool) {
        return _held(this.invariant_noSharesNoPrincipal);
    }
    function property_poolIndexAlive() public view returns (bool) {
        return _held(this.invariant_poolIndexAlive);
    }
    function property_lifetimeDeductionReconciles() public view returns (bool) {
        return _held(this.invariant_lifetimeDeductionReconciles);
    }
    function property_noBurnWithoutDistribution() public view returns (bool) {
        return _held(this.invariant_noBurnWithoutDistribution);
    }
    function property_perSettlementRateCap() public view returns (bool) {
        return _held(this.invariant_perSettlementRateCap);
    }
    function property_decayWindowCeiling() public view returns (bool) {
        return _held(this.invariant_decayWindowCeiling);
    }
    function property_stallCannotBeClosedEarly() public view returns (bool) {
        return _held(this.invariant_stallCannotBeClosedEarly);
    }
    function property_burnAlwaysMovesPoolIndex() public view returns (bool) {
        return _held(this.invariant_burnAlwaysMovesPoolIndex);
    }
    function property_arrivalsAreQuarantined() public view returns (bool) {
        return _held(this.invariant_arrivalsAreQuarantined);
    }
    function property_bystanderIsNotSandwichable() public view returns (bool) {
        return _held(this.invariant_bystanderIsNotSandwichable);
    }
}
