// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {HCOWProfitShare} from "../contracts/HCOWProfitShare.sol";
import {MockHCOW, MockUSDT} from "../contracts/test/Mocks.sol";

/**
 * @title HalmosProfitShare
 * @notice The two money rules, proved rather than sampled.
 *
 * Foundry and Medusa both SAMPLE the input space. They found nothing here, but
 * "nothing found in 300,000 calls" is not the same claim as "cannot happen",
 * and the difference is exactly where this session's first High lived: the
 * Rule 6 gate passed at one wei of revenue, and no sampler tried one wei of
 * revenue against a large carry because a sampler has no reason to.
 *
 * Halmos executes settleEpoch once over a SYMBOLIC input and asks a solver
 * whether any assignment breaks the property. One epoch is the right depth:
 * both rules are per-epoch conditions on the settlement that is happening, so
 * a single symbolic settlement covers every settlement.
 *
 * Run: npm run test:halmos
 */
contract HalmosProfitShare is Test {
    uint256 internal constant MIN_POOL = 1_000e18;

    HCOWProfitShare internal ps;
    MockHCOW internal hcow;
    MockUSDT internal usdt;

    address internal owner   = address(0xA11CE0);
    address internal settler = address(0x5E771E);
    address internal gameCo  = address(0x6A3EC0);
    address internal team    = address(0x7EA300);
    address internal holder  = address(0x1001);

    function setUp() public {
        hcow = new MockHCOW();
        usdt = new MockUSDT();
        ps = new HCOWProfitShare(address(hcow), address(usdt), owner, settler, gameCo, team, MIN_POOL);

        hcow.transfer(holder, 10_000_000e18);
        vm.prank(holder);
        hcow.approve(address(ps), type(uint256).max);
        vm.prank(holder);
        ps.bond(2_000e18);

        usdt.mint(settler, type(uint128).max);
        vm.prank(settler);
        usdt.approve(address(ps), type(uint256).max);

        // one settlement so the position is out of quarantine and the pool the
        // rules talk about actually exists
        vm.warp(block.timestamp + 8 days);
        vm.prank(settler);
        ps.settleEpoch(0, 1_000e18, 0, 0, 0);
        vm.warp(block.timestamp + 8 days);
    }

    /**
     * Rule 6, for every input rather than for the inputs someone typed.
     *
     * No epoch may consume bonded principal unless that same epoch credited
     * participants at least MIN_PARTICIPANT_USDT. The defect this replaces was
     * a gate that measured the credit INCLUDING the carried leg from earlier
     * epochs, so a one wei settlement against a 300,000 USDT carry burned
     * 200,000 HCOW of principal and passed.
     */
    function check_noPrincipalBurnedWithoutADistribution(
        uint256 gross,
        uint256 direct,
        uint256 opex,
        uint32 ppm
    ) public {
        vm.assume(gross <= 1_000_000e18);
        vm.assume(direct <= gross);
        vm.assume(opex <= 1_000_000e18);

        uint256 poolBefore = ps.totalBondedHcow();
        vm.prank(settler);
        try ps.settleEpoch(1, gross, direct, opex, ppm) {
            HCOWProfitShare.Settlement memory s = ps.getSettlement(1);
            if (ps.totalBondedHcow() < poolBefore) {
                assertGe(s.participantsUsdt, ps.MIN_PARTICIPANT_USDT());
            }
        } catch {
            // a reverted settlement changes nothing, which is the rule holding
        }
    }

    /**
     * Rule 5, per settlement, for every input.
     *
     * A single settlement may not take more of the pool than MAX_DEDUCT_PPM,
     * whatever rate the settler states and whatever the pool is doing. One wei
     * of slack for the rounding in the share burn.
     */
    function check_oneSettlementCannotExceedThePerSettlementCap(
        uint256 gross,
        uint256 direct,
        uint256 opex,
        uint32 ppm
    ) public {
        vm.assume(gross <= 1_000_000e18);
        vm.assume(direct <= gross);
        vm.assume(opex <= 1_000_000e18);

        uint256 poolBefore = ps.totalBondedHcow();
        vm.prank(settler);
        try ps.settleEpoch(1, gross, direct, opex, ppm) {
            uint256 taken = poolBefore - ps.totalBondedHcow();
            // taken / poolBefore <= MAX_DEDUCT_PPM / 1e6, without dividing
            assertLe(taken * 1_000_000, poolBefore * uint256(ps.MAX_DEDUCT_PPM()) + 1_000_000);
        } catch {}
    }

    /**
     * The waterfall conserves, for every input.
     *
     * Everything the contract pulled in for this epoch either went to one of
     * the three legs or is sitting in the carry. Nothing evaporates and nothing
     * is created.
     */
    function check_theWaterfallConserves(
        uint256 gross,
        uint256 direct,
        uint256 opex,
        uint32 ppm
    ) public {
        vm.assume(gross <= 1_000_000e18);
        vm.assume(direct <= gross);
        vm.assume(opex <= 1_000_000e18);

        uint256 carryBefore = ps.carriedParticipantUsdt();
        vm.prank(settler);
        try ps.settleEpoch(1, gross, direct, opex, ppm) {
            HCOWProfitShare.Settlement memory s = ps.getSettlement(1);
            uint256 carryAfter = ps.carriedParticipantUsdt();
            assertEq(
                s.participantsUsdt + s.gameCompanyUsdt + s.teamUsdt + carryAfter,
                s.distributableProfitUsdt + carryBefore
            );
        } catch {}
    }
}
