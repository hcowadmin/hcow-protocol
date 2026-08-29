// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {HCOWStaking} from "../contracts/HCOWStaking.sol";
import {MockHCOW} from "../contracts/test/Mocks.sol";

contract RateFloorTest is Test {
    HCOWStaking st; MockHCOW hcow;
    address owner = address(0x01); address funder = address(0xF1); address alice = address(0xA1);
    bytes32 rep = keccak256("r");

    function setUp() public {
        vm.warp(1_800_000_000);
        hcow = new MockHCOW();
        st = new HCOWStaking(address(hcow), owner, funder);
        vm.prank(owner); st.registerRepresentative(rep, "r", address(0x9), 0, true);
        hcow.transfer(funder, 100_000_000e18);
        hcow.transfer(alice, 1_000e18);
        vm.prank(funder); hcow.approve(address(st), type(uint256).max);
        vm.prank(alice); hcow.approve(address(st), type(uint256).max);
        vm.prank(alice); st.stake(1_000e18, rep);
    }

    /// One wei must not be able to slow a live stream. This is the property the
    /// source states in prose; it is asserted here directly.
    function test_oneWeiCannotSlowALiveStream() public {
        vm.prank(funder); st.fundRewards(8_640_000e18, 100 days);
        uint256 rate0 = st.rewardRate();
        emit log_named_uint("rate after the real funding", rate0);

        vm.warp(st.periodFinish() - 43_200);
        vm.prank(funder);
        try st.fundRewards(1, 1 days) {
            emit log_named_uint("rate after a one wei funding", st.rewardRate());
            assertGe(st.rewardRate(), rate0, "one wei slowed the stream");
        } catch {
            emit log("one wei funding refused, as it must be");
        }

        vm.warp(st.periodFinish() - 1);
        uint256 rateBefore = st.rewardRate();
        vm.prank(funder);
        try st.fundRewards(1, 1 days) {
            emit log_named_uint("rate one second before the end", st.rewardRate());
            assertGe(st.rewardRate(), rateBefore, "one wei slowed the stream at the very end");
        } catch {
            emit log("one wei at the very end refused, as it must be");
        }
    }

    /// A real top-up in the tail window should still be possible where it does
    /// not slow anything. This is the case the earlier fix was written for.
    function test_realTopUpInTheTailWindow() public {
        vm.prank(funder); st.fundRewards(10_000e18, 30 days);
        uint256 rate0 = st.rewardRate();
        vm.warp(st.periodFinish() - 60);
        vm.prank(funder);
        st.fundRewards(9_900_000e18, 1 days);
        emit log_named_uint("rate before", rate0);
        emit log_named_uint("rate after a 9,900,000 top up at 60s remaining", st.rewardRate());
        assertGe(st.rewardRate(), rate0, "a real top up slowed the stream");
    }
}
