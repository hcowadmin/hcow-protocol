// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HCOWProfitShare} from "../contracts/HCOWProfitShare.sol";
import {MockHCOW, MockUSDT} from "../contracts/test/Mocks.sol";

/**
 * Every way found so far of moving the participant leg somewhere it does not
 * belong, asserted as a test rather than described in a comment.
 */
contract SandwichTest is Test {
    HCOWProfitShare ps; MockHCOW hcow; MockUSDT usdt;
    address owner = address(0x01); address settler = address(0x02);
    address gameCo = address(0x03); address team = address(0x04);
    address alice = address(0x05); address whale = address(0x06);

    function setUp() public {
        vm.warp(1_800_000_000);
        hcow = new MockHCOW(); usdt = new MockUSDT();
        ps = new HCOWProfitShare(address(hcow), address(usdt), owner, settler, gameCo, team);
        usdt.mint(settler, 500_000_000e18);
        vm.prank(settler); usdt.approve(address(ps), type(uint256).max);
        hcow.transfer(alice, 10_000e18);
        hcow.transfer(whale, 10_000_000e18);
        vm.prank(alice); hcow.approve(address(ps), type(uint256).max);
        vm.prank(whale); hcow.approve(address(ps), type(uint256).max);
    }

    function _open() internal {
        vm.prank(alice); ps.bond(1_000e18);
        vm.prank(whale); ps.bond(999_000e18);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(settler); ps.settleEpoch(0, 100e18, 100e18, 0, 0);   // nil, makes them eligible
        vm.warp(block.timestamp + 7 days + 1);
    }

    /// Bonding in the settlement block must not move the leg.
    function test_bondSandwichDoesNothing() public {
        _open();
        vm.prank(settler); ps.settleEpoch(1, 200_000e18, 0, 0, 0);
        uint256 clean = ps.getSettlement(1).participantsUsdt;

        setUp(); _open();
        vm.prank(whale); ps.bond(9_000_000e18);
        vm.prank(settler); ps.settleEpoch(1, 200_000e18, 0, 0, 0);
        assertEq(ps.getSettlement(1).participantsUsdt, clean, "a bond in the settlement block moved the leg");
    }

    /// requestUnbond followed by cancelUnbond in one block removes a position
    /// from eligibleShares and puts it back, at zero cost. It must not move
    /// the leg either.
    function test_flipSandwichDoesNothing() public {
        _open();
        vm.prank(settler); ps.settleEpoch(1, 200_000e18, 0, 0, 0);
        uint256 clean = ps.getSettlement(1).participantsUsdt;

        setUp(); _open();
        uint256 whaleBefore = hcow.balanceOf(whale);
        vm.startPrank(whale);
        ps.requestUnbond(ps.bondedOf(whale));
        ps.cancelUnbond();
        vm.stopPrank();
        assertEq(hcow.balanceOf(whale), whaleBefore, "the flip was not free, so the premise is wrong");

        vm.prank(settler); ps.settleEpoch(1, 200_000e18, 0, 0, 0);
        assertEq(ps.getSettlement(1).participantsUsdt, clean,
            "a requestUnbond/cancelUnbond flip in the settlement block moved the leg");
    }

    /// An ordinary exit during an epoch must give that holder's share to the
    /// holders who stayed, not to the two fixed recipients.
    function test_midEpochExitDoesNotEnrichTheRecipients() public {
        vm.prank(alice); ps.bond(500_000e18 / 1000);      // 500 HCOW
        vm.prank(whale); ps.bond(500_000e18 / 1000);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(settler); ps.settleEpoch(0, 100e18, 100e18, 0, 0);
        vm.warp(block.timestamp + 7 days + 1);

        // read first: vm.prank applies to the very next call, and a view call
        // inside an argument list is that next call
        uint256 whaleOwned = ps.bondedOf(whale);
        vm.prank(whale); ps.requestUnbond(whaleOwned);            // a real exit
        vm.prank(settler); ps.settleEpoch(1, 200_000e18, 0, 0, 0);

        HCOWProfitShare.Settlement memory st = ps.getSettlement(1);
        assertEq(st.participantsUsdt, 100_000e18, "the leaver's share did not go to the holder who stayed");
        assertEq(uint256(st.gameCompanyUsdt) + st.teamUsdt, 100_000e18, "the recipients took more than their half");
        assertEq(ps.claimableOf(alice), 100_000e18, "the remaining holder was not credited the whole leg");
    }

    /// The launch-window floor still bites, and only in the launch window.
    function test_dustPoolCannotTakeARealDistribution() public {
        vm.prank(alice); ps.bond(1);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(settler); ps.settleEpoch(0, 100e18, 100e18, 0, 0);
        vm.prank(whale); ps.bond(10_000_000e18);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(settler); ps.settleEpoch(1, 600_000e18, 0, 0, 0);

        assertLt(ps.claimableOf(alice), 1e18, "one wei took a real distribution");
        HCOWProfitShare.Settlement memory st = ps.getSettlement(1);
        assertGt(uint256(st.gameCompanyUsdt) + st.teamUsdt, 599_999e18, "the leg did not go to the recipients");

        // and the next epoch, with a real pool, is normal again
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(settler); ps.settleEpoch(2, 600_000e18, 0, 0, 0);
        assertApproxEqRel(ps.claimableOf(whale), 300_000e18, 1e12, "a real pool did not take the whole leg");
    }
}
