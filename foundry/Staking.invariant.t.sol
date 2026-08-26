// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HCOWStaking} from "../contracts/HCOWStaking.sol";
import {MockHCOW} from "../contracts/test/Mocks.sol";
import {StakingHandler} from "./handlers/StakingHandler.sol";

/**
 * @title StakingInvariants
 * @notice Properties a machine searches for counterexamples to.
 *
 * The funding rules in fundRewards were rewritten three times, each time
 * because a hand-constructed scenario broke the previous version. The rules
 * are stated in prose in the source: "a funding may add tokens or add time. It
 * may never redistribute what is already promised." Nothing asserted that
 * directly. These do.
 */
contract StakingInvariants is Test {
    HCOWStaking internal st;
    MockHCOW internal hcow;
    StakingHandler internal handler;

    address internal owner  = address(0x0FFEE0);
    address internal funder = address(0xF0DDE1);

    function setUp() public {
        hcow = new MockHCOW();
        st = new HCOWStaking(address(hcow), owner, funder);

        bytes32[] memory reps = new bytes32[](3);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; ++i) {
            reps[i] = keccak256(abi.encodePacked("rep", i));
            st.registerRepresentative(
                reps[i], "rep", address(uint160(0x9000 + i)), uint16(i * 300), i == 0
            );
        }
        vm.stopPrank();

        address[] memory actors = new address[](6);
        for (uint256 i = 0; i < 6; ++i) {
            actors[i] = address(uint160(0x2000 + i));
            hcow.transfer(actors[i], 5_000_000e18);
            vm.prank(actors[i]);
            hcow.approve(address(st), type(uint256).max);
        }
        hcow.transfer(funder, 100_000_000e18);
        vm.prank(funder);
        hcow.approve(address(st), type(uint256).max);

        handler = new StakingHandler(st, hcow, funder, owner, actors, reps);
        targetContract(address(handler));
    }

    // ------------------------------------------------- the funding contract

    /// A funding may never slow the stream already running.
    function invariant_fundingNeverSlowsTheStream() public view {
        assertEq(handler.ghostRateDrops(), 0, "a funding lowered the rate of a live period");
    }

    /// A funding may never pull the end date in and compress what is promised.
    function invariant_fundingNeverPullsTheEndDateIn() public view {
        assertEq(handler.ghostFinishPullIns(), 0, "a funding moved periodFinish backwards");
    }

    // ------------------------------------------------------------- solvency

    function invariant_hcowBacked() public view {
        uint256 owedRewards;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) owedRewards += st.pendingRewardOf(handler.actorAt(i));
        uint256 owedCommission;
        uint256 m = handler.repCount();
        for (uint256 i = 0; i < m; ++i) owedCommission += st.commissionOf(handler.repAt(i));
        assertGe(
            hcow.balanceOf(address(st)),
            st.totalStaked() + st.totalPendingUnstake() + owedRewards + owedCommission,
            "contract holds less HCOW than principal plus what it owes in rewards"
        );
    }

    /**
     * Rewards cannot be created. Everything owed, everything already claimed
     * and everything still undistributed can never exceed what was funded.
     * One wei of slack per party for the floored accumulator products.
     */
    function invariant_noRewardCreation() public view {
        uint256 n = handler.actorCount();
        uint256 m = handler.repCount();
        uint256 owed;
        uint256 claimed;
        for (uint256 i = 0; i < n; ++i) {
            owed += st.pendingRewardOf(handler.actorAt(i));
            (,,,,, uint256 lifetime) = st.delegationOf(handler.actorAt(i));
            claimed += lifetime;
        }
        for (uint256 i = 0; i < m; ++i) owed += st.commissionOf(handler.repAt(i));
        assertLe(
            owed + claimed,
            st.totalRewardsFunded() + n + m,
            "more HCOW is owed or has been paid than was ever funded"
        );
    }

    // ----------------------------------------------------------- accounting

    function invariant_stakeConservation() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) {
            (, uint256 staked,,,,) = st.delegationOf(handler.actorAt(i));
            sum += staked;
        }
        assertEq(sum, st.totalStaked(), "delegated stake does not sum to totalStaked");
    }

    function invariant_repWeightConservation() public view {
        uint256 sum;
        uint256 m = handler.repCount();
        for (uint256 i = 0; i < m; ++i) {
            (,,,,, uint256 delegated,,) = st.representativeOf(handler.repAt(i));
            sum += delegated;
        }
        assertEq(sum, st.totalStaked(), "representative weights do not sum to totalStaked");
    }

    function invariant_pendingConservation() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) {
            (,, uint256 pending,,,) = st.delegationOf(handler.actorAt(i));
            sum += pending;
        }
        assertEq(sum, st.totalPendingUnstake(), "pending unstakes do not sum to the total");
    }

    function invariant_periodFinishNotInThePast() public view {
        // Either no period was ever funded, or the end date is a real time.
        if (st.rewardRate() > 0) assertGt(st.periodFinish(), 0, "a live rate with no end date");
    }
}
