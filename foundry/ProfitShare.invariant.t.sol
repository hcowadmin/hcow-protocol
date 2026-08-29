// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {HCOWProfitShare} from "../contracts/HCOWProfitShare.sol";
import {MockHCOW, MockUSDT} from "../contracts/test/Mocks.sol";
import {ProfitShareHandler} from "./handlers/ProfitShareHandler.sol";

/**
 * @title ProfitShareInvariants
 * @notice Properties a machine searches for counterexamples to.
 *
 * The hand-written suite in test/ replays sequences its author thought of. It
 * has been wrong about what to think of, repeatedly, and every time the miss
 * was a sequence rather than an arithmetic slip. This file states the
 * properties and lets the fuzzer look for the sequence.
 *
 * Run: forge test --match-contract ProfitShareInvariants
 * Deep: FOUNDRY_PROFILE=deep forge test --match-contract ProfitShareInvariants
 */
contract ProfitShareInvariants is Test {
    /// The participant floor, set to this campaign's own scale. Mainnet uses
    /// 1,000,000e18 against a 200,000,000 supply; the campaign works in pools
    /// of a few thousand, so a floor at mainnet scale would leave every
    /// settlement in the sub-floor branch and the campaign would observe
    /// nothing else.
    uint256 internal constant MIN_POOL = 1_000e18;

    HCOWProfitShare internal ps;
    MockHCOW internal hcow;
    MockUSDT internal usdt;
    ProfitShareHandler internal handler;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal owner   = address(0xA11CE0);
    address internal settler = address(0x5E771E);
    address internal gameCo  = address(0x6A3EC0);
    address internal team    = address(0x7EA300);

    function setUp() public {
        hcow = new MockHCOW();
        usdt = new MockUSDT();
        ps = new HCOWProfitShare(address(hcow), address(usdt), owner, settler, gameCo, team, MIN_POOL);

        // MockHCOW mints its whole fixed supply to the deployer, exactly as
        // HCOWToken does, so the actors are funded from here rather than minted.
        address[] memory actors = new address[](6);
        for (uint256 i = 0; i < 6; ++i) {
            actors[i] = address(uint160(0x1000 + i));
            hcow.transfer(actors[i], 2_000_000e18);
            vm.prank(actors[i]);
            hcow.approve(address(ps), type(uint256).max);
        }
        usdt.mint(settler, 500_000_000e18);
        vm.prank(settler);
        usdt.approve(address(ps), type(uint256).max);

        handler = new ProfitShareHandler(ps, hcow, usdt, settler, actors);
        // the handler pranks as the actors, so it needs no balance of its own
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- price

    /**
     * The pool price is totalBondedHcow / totalShares. Only a settlement may
     * move it down, because only a settlement destroys principal. Any other
     * path that lowers it is taking value from the holders who stayed and
     * giving it to whoever acted, one wei at a time.
     *
     * This is the property that caught the floored `sharesToBurn` in
     * requestUnbond, which is the same shape as the Balancer rounding loss.
     */
    function invariant_priceNeverFallsOutsideSettlement() public view {
        assertEq(handler.ghostPriceDrops(), 0, "pool price fell outside a settlement");
    }

    // ------------------------------------------------------------- solvency

    function invariant_hcowBacked() public view {
        assertGe(
            hcow.balanceOf(address(ps)),
            ps.totalBondedHcow() + ps.totalPendingUnbond(),
            "contract holds less HCOW than it owes"
        );
    }

    /**
     * Everything the contract owes, not just what is claimable.
     *
     * `carriedParticipantUsdt` is a withheld participant leg the contract is
     * holding for the first real pool. It is an obligation with no claimant yet,
     * so summing claimableOf alone would not have noticed an unbacked carry: the
     * property would have passed with the carry paid out twice.
     */
    function invariant_usdtSolvent() public view {
        uint256 owed = ps.carriedParticipantUsdt();
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) owed += ps.claimableOf(handler.actorAt(i));
        assertGe(usdt.balanceOf(address(ps)), owed,
            "contract owes more USDT than it holds, counting the carry");
    }

    function invariant_burnAccounted() public view {
        assertEq(
            hcow.balanceOf(DEAD),
            ps.totalHcowDeducted() + ps.totalHcowForfeited(),
            "burned HCOW does not match the two counters"
        );
    }

    // ------------------------------------------------------------- accounting

    function invariant_shareConservation() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 shares,,) = ps.accountOf(handler.actorAt(i));
            sum += shares;
        }
        assertEq(sum, ps.totalShares(), "share sum does not match totalShares");
    }

    function invariant_pendingConservation() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) {
            (,, uint256 pending,) = ps.accountOf(handler.actorAt(i));
            sum += pending;
        }
        assertEq(sum, ps.totalPendingUnbond(), "pending sum does not match totalPendingUnbond");
    }

    function invariant_newSharesBounded() public view {
        assertLe(ps.totalNewShares(), ps.totalShares(), "new shares exceed total shares");
    }

    function invariant_noSharesNoPrincipal() public view {
        if (ps.totalShares() == 0) {
            assertEq(ps.totalBondedHcow(), 0, "principal with no shares to own it");
        }
    }

    function invariant_poolIndexAlive() public view {
        assertGt(ps.poolIndex(), 0, "poolIndex reached zero");
    }

    /**
     * Every account's lifetime deduction, summed, cannot exceed the burn that
     * actually happened. One wei of slack per account for the ceil-rounded
     * debt bookmark.
     */
    function invariant_lifetimeDeductionReconciles() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) {
            (uint256 deducted,) = ps.lifetimeOf(handler.actorAt(i));
            sum += deducted;
        }
        assertLe(
            sum,
            ps.totalHcowDeducted() + ps.totalHcowForfeited() + n,
            "published lifetime deduction exceeds the actual burn"
        );
    }

    // ----------------------------------------------------------- the policy

    /**
     * These are the guards the whitepaper actually promises, and every one of
     * them could be deleted from the contract while the accounting invariants
     * above kept passing. Conservation is the easy half; what bounds the
     * settler is the half the money depends on.
     */

    /// Rule 6. Principal is only consumed by an epoch that really paid participants.
    function invariant_noBurnWithoutDistribution() public view {
        assertEq(handler.ghostRule6Breaches(), 0,
            "principal was burned in an epoch that credited less than one USDT");
    }

    /// Rule 5, per settlement. The rate the settler states is capped.
    function invariant_perSettlementRateCap() public view {
        assertEq(handler.ghostRateCapBreaches(), 0,
            "a settlement above MAX_DEDUCT_PPM was accepted");
        assertLe(handler.ghostWorstSingleDropPpm(), uint256(ps.MAX_DEDUCT_PPM()) + 1,
            "one settlement took more of the pool than the per settlement cap allows");
    }

    /// Rule 5, per window. The campaign ceiling is a rate and it is enforced.
    function invariant_decayWindowCeiling() public view {
        assertLe(ps.decayWindowPpm(), uint256(ps.MAX_DECAY_PER_WINDOW_PPM()),
            "the decay window ceiling was exceeded");
    }

    /// A burn must move poolIndex, or a pending unbond sits through a
    /// settlement it is never charged for and the dodge that H-2 closed reopens.
    /// An epoch cannot be closed as stalled before its deadline, and the
    /// deadline is measured from a settlement that actually happened.
    function invariant_stallCannotBeClosedEarly() public view {
        assertEq(handler.ghostStallClosedTooEarly(), 0,
            "an epoch was closed as stalled before its deadline");
    }

    function invariant_burnAlwaysMovesPoolIndex() public view {
        assertEq(handler.ghostIndexStalls(), 0,
            "a settlement burned principal without moving poolIndex");
    }

    /// Eligibility deferral. Shares bonded during an epoch earn nothing from it.
    function invariant_arrivalsAreQuarantined() public view {
        assertEq(handler.ghostQuarantineBreaks(), 0,
            "a same-epoch arrival was credited by the epoch it arrived in");
    }

    /**
     * Nothing anyone does in the settlement block may reduce what a holder who
     * did nothing is paid.
     *
     * Two free levers exist: bonding, which inflates the pool, and requesting
     * an unbond and cancelling it in the same block, which removes a position
     * from the eligible pool and puts it back. Both were measured moving an
     * honest holder's 100,000 USDT to 100 under earlier divisors.
     */
    function invariant_bystanderIsNotSandwichable() public view {
        assertEq(handler.ghostDivisorMoved(), 0,
            "an action in the settlement block reduced a passive holder's credit");
        // Belt and braces: the tolerance above is four wei, so anything that
        // looks like value rather than rounding fails here regardless of how
        // the counter is written.
        assertLe(handler.ghostWorstBystanderDrop(), 4,
            "a passive holder lost more than rounding to somebody else's action");
    }

    /**
     * Coverage, asserted rather than hoped for.
     *
     * The previous version of this function asserted that an unsigned counter
     * was greater than or equal to zero, which is true of every unsigned
     * counter and therefore said nothing: a campaign in which every single
     * call reverted would have passed it, and every property above it would
     * have passed too, on an empty state. The audit was right to call that
     * out.
     *
     * These are the states the properties above are actually about. If a
     * campaign does not reach them, the campaign proved nothing and is failed
     * rather than reported green.
     *
     * afterInvariant rather than an invariant: invariant functions are also
     * evaluated once before any call is made, where a coverage floor can only
     * fail. That is the same mistake in a different place.
     */
    function afterInvariant() public view {
        assertGt(handler.ghostBonds(), 0, "no bond landed, so the pool was never populated");
        assertGt(handler.ghostSettlements(), 0, "no settlement landed, so nothing was distributed");
        assertGt(handler.ghostDeductions(), 0,
            "no settlement consumed principal, so every burn property observed nothing");
        assertGt(handler.ghostOverCapRefused(), 0,
            "an over-cap rate was never offered and refused, so the cap was never exercised");
        assertGt(handler.ghostUnbondRequests(), 0, "nobody ever left, so the exit path was never taken");
        assertGt(handler.ghostClaims(), 0, "nobody ever claimed, so the payout path was never taken");
        assertEq(handler.ghostOverCapAccepted(), 0, "a rate above the cap was accepted");
        assertGt(handler.ghostStallCloses(), 0,
            "no epoch was ever closed as stalled, so that path observed nothing");
    }
}
