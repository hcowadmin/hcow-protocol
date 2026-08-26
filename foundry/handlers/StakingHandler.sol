// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HCOWStaking} from "../../contracts/HCOWStaking.sol";
import {MockHCOW} from "../../contracts/test/Mocks.sol";

/**
 * @title StakingHandler
 * @notice Bounded action generator for the staking invariant run.
 *
 * Records ghosts for the two claims the funding rules make in prose but that
 * no test asserted directly: that a funding may never slow the stream already
 * running, and may never pull its end date in.
 */
contract StakingHandler is Test {
    HCOWStaking public immutable st;
    MockHCOW public immutable hcow;
    address public immutable funder;
    address public immutable owner;

    address[] public actors;
    bytes32[] public reps;
    address internal current;

    uint256 public ghostRateDrops;      // rewardRate fell while a period was live
    uint256 public ghostFinishPullIns;  // periodFinish moved backwards
    uint256 public ghostFundings;
    uint256 public ghostLastRate;
    uint64  public ghostLastFinish;

    modifier useActor(uint256 seed) {
        current = actors[bound(seed, 0, actors.length - 1)];
        vm.startPrank(current);
        _;
        vm.stopPrank();
    }

    constructor(
        HCOWStaking st_, MockHCOW hcow_, address funder_, address owner_,
        address[] memory actors_, bytes32[] memory reps_
    ) {
        st = st_; hcow = hcow_; funder = funder_; owner = owner_;
        for (uint256 i = 0; i < actors_.length; ++i) actors.push(actors_[i]);
        for (uint256 i = 0; i < reps_.length; ++i) reps.push(reps_[i]);
    }

    function actorCount() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
    function repCount() external view returns (uint256) { return reps.length; }
    function repAt(uint256 i) external view returns (bytes32) { return reps[i]; }

    function _amount(uint256 seed, uint256 max) internal pure returns (uint256) {
        if (max == 0) return 0;
        uint256 k = seed % 8;
        if (k == 0) return 1;
        if (k == 1) return max;
        if (k == 2) return max > 1 ? max - 1 : max;
        if (k == 3) return 1e18;               // exactly MIN_STAKE_FOR_ACCRUAL
        if (k == 4) return max > 1e18 ? 1e18 - 1 : max;
        return bound(seed, 1, max);
    }

    function stake(uint256 actorSeed, uint256 amtSeed, uint256 repSeed) external useActor(actorSeed) {
        uint256 bal = hcow.balanceOf(current);
        if (bal == 0) return;
        bytes32 id = reps[bound(repSeed, 0, reps.length - 1)];
        try st.stake(_amount(amtSeed, bal > 1_000_000e18 ? 1_000_000e18 : bal), id) {} catch {}
    }

    function redelegate(uint256 actorSeed, uint256 repSeed) external useActor(actorSeed) {
        try st.redelegate(reps[bound(repSeed, 0, reps.length - 1)]) {} catch {}
    }

    function requestUnstake(uint256 actorSeed, uint256 amtSeed) external useActor(actorSeed) {
        (, uint256 staked,,,,) = st.delegationOf(current);
        if (staked == 0) return;
        try st.requestUnstake(_amount(amtSeed, staked)) {} catch {}
    }

    function cancelUnstake(uint256 actorSeed) external useActor(actorSeed) {
        try st.cancelUnstake() {} catch {}
    }

    function withdrawUnstaked(uint256 actorSeed) external useActor(actorSeed) {
        try st.withdrawUnstaked() {} catch {}
    }

    function claimHcow(uint256 actorSeed) external useActor(actorSeed) {
        try st.claimHcow() {} catch {}
    }

    function claimCommission(uint256 repSeed) external {
        try st.claimCommission(reps[bound(repSeed, 0, reps.length - 1)]) {} catch {}
    }

    function updateRep(uint256 repSeed, uint256 bpsSeed, uint256 activeSeed) external {
        bytes32 id = reps[bound(repSeed, 0, reps.length - 1)];
        (, address payout,,,,,,) = st.representativeOf(id);
        vm.startPrank(owner);
        try st.updateRepresentative(id, payout, uint16(bound(bpsSeed, 0, 1000)), activeSeed % 2 == 0) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 60 days));
    }

    /**
     * The funding rules are the thing under test. Record the rate and the end
     * date before and after so the invariants can assert what the comments
     * claim: a funding may add tokens or add time, never redistribute what is
     * already promised.
     */
    function fund(uint256 amtSeed, uint256 durSeed) external {
        uint256 amount = _amount(amtSeed, 20_000_000e18);
        uint64 duration = uint64(bound(durSeed, 1, 366 days));
        uint256 rateBefore = st.rewardRate();
        uint64 finishBefore = st.periodFinish();
        bool wasLive = block.timestamp < finishBefore;

        vm.startPrank(funder);
        try st.fundRewards(amount, duration) {
            ghostFundings += 1;
            if (wasLive) {
                if (st.rewardRate() < rateBefore) ghostRateDrops += 1;
                if (st.periodFinish() < finishBefore) ghostFinishPullIns += 1;
            }
        } catch {}
        vm.stopPrank();
        ghostLastRate = st.rewardRate();
        ghostLastFinish = st.periodFinish();
    }
}
