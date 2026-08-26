// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HCOWProfitShare} from "../../contracts/HCOWProfitShare.sol";
import {MockHCOW, MockUSDT} from "../../contracts/test/Mocks.sol";

/**
 * @title ProfitShareHandler
 * @notice Bounded action generator for the invariant run.
 *
 * The point of a handler is to keep the fuzzer inside the region where calls
 * actually land, without narrowing it to the sequences a person would write.
 * Amounts are bounded, but deliberately biased toward the values a person does
 * NOT write: one wei, one less than the whole position, and exact boundaries.
 * Every defect found in this contract by hand lived at one of those.
 */
contract ProfitShareHandler is Test {
    HCOWProfitShare public immutable ps;
    MockHCOW public immutable hcow;
    MockUSDT public immutable usdt;
    address public immutable settler;

    address[] public actors;
    address internal current;

    // ---- ghosts the invariants read ----
    uint256 public ghostPriceRay;          // last observed totalBondedHcow*1e27/totalShares
    uint256 public ghostPriceDrops;        // times it fell outside a settlement
    uint256 public ghostWorstDropRay;
    uint256 public ghostSettlements;
    bool    public inSettlement;

    // ---- policy ghosts ----
    // Accounting invariants hold when every economic guard in the contract is
    // deleted. They cover conservation, not policy, and policy is what the
    // whitepaper promises. These record the guards themselves.
    uint256 public ghostRule6Breaches;      // principal burned without a real distribution
    uint256 public ghostRateCapBreaches;    // one settlement took more than MAX_DEDUCT_PPM
    uint256 public ghostIndexStalls;        // a burn that did not move poolIndex
    uint256 public ghostQuarantineBreaks;   // a same-epoch arrival earned from that epoch
    uint256 public ghostWorstSingleDropPpm;
    uint256 public ghostDivisorMoved;    // a bystander was materially worse off
    uint256 public ghostWorstBystanderDrop;  // the largest reduction seen, in wei

    // Arrivals waiting to be checked against the settlement that follows them.
    //
    // Only FIRST-TIME arrivals are recorded. An account that already held
    // eligible shares earns from those legitimately in the same settlement,
    // and comparing its claimable before and after conflates the two: the
    // first version of this ghost did exactly that and reported the contract
    // as broken when it was the ghost that was wrong. An account whose share
    // count was zero before the bond has nothing but new shares, so its credit
    // from that epoch must be exactly zero.
    mapping(address => uint64) internal arrivedInEpoch;
    // An account that fully unbonds keeps its unclaimed USDT, so "shares were
    // zero" is not the same as "owed nothing". The quarantine property is
    // about NEW credit, so the balance at arrival is what it must be compared
    // against.
    mapping(address => uint256) internal claimableAtArrival;

    uint256 internal constant RAY = 1e27;
    uint256 internal lastPoolIndex = type(uint256).max;

    modifier useActor(uint256 seed) {
        current = actors[bound(seed, 0, actors.length - 1)];
        vm.startPrank(current);
        _;
        vm.stopPrank();
        _afterAction();
    }

    constructor(HCOWProfitShare ps_, MockHCOW hcow_, MockUSDT usdt_, address settler_, address[] memory actors_) {
        ps = ps_; hcow = hcow_; usdt = usdt_; settler = settler_;
        for (uint256 i = 0; i < actors_.length; ++i) actors.push(actors_[i]);
        ghostPriceRay = RAY;
    }

    function actorCount() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }

    function _price() internal view returns (uint256) {
        uint256 s = ps.totalShares();
        if (s == 0) return ghostPriceRay;
        return (ps.totalBondedHcow() * RAY) / s;
    }

    function _afterAction() internal {
        uint256 p = _price();
        if (!inSettlement && p < ghostPriceRay) {
            ghostPriceDrops += 1;
            uint256 d = ghostPriceRay - p;
            if (d > ghostWorstDropRay) ghostWorstDropRay = d;
        }
        ghostPriceRay = p;
        inSettlement = false;
    }

    /// Amounts a person would not type. Half the draws are pathological.
    function _amount(uint256 seed, uint256 max) internal pure returns (uint256) {
        if (max == 0) return 0;
        uint256 k = seed % 8;
        if (k == 0) return 1;
        if (k == 1) return max;
        if (k == 2) return max > 1 ? max - 1 : max;
        if (k == 3) return max / 2 + 1;
        if (k == 4) return 2;
        return bound(seed, 1, max);
    }

    function bond(uint256 actorSeed, uint256 amtSeed) external useActor(actorSeed) {
        uint256 bal = hcow.balanceOf(current);
        if (bal == 0) return;
        uint256 amt = _amount(amtSeed, bal > 5_000_000e18 ? 5_000_000e18 : bal);
        (, uint256 sharesBefore,,) = ps.accountOf(current);
        uint256 owedBefore = ps.claimableOf(current);
        try ps.bond(amt) {
            // Only an account holding no shares is a clean test: one that
            // already holds eligible shares earns from those legitimately in
            // the same settlement.
            if (sharesBefore == 0 && arrivedInEpoch[current] == 0) {
                arrivedInEpoch[current] = ps.nextEpoch() + 1;   // +1 so 0 means "not recorded"
                claimableAtArrival[current] = owedBefore;
            }
        } catch {}
    }

    function requestUnbond(uint256 actorSeed, uint256 amtSeed) external useActor(actorSeed) {
        uint256 owned = ps.bondedOf(current);
        if (owned == 0) return;
        try ps.requestUnbond(_amount(amtSeed, owned)) {} catch {}
    }

    function cancelUnbond(uint256 actorSeed) external useActor(actorSeed) {
        try ps.cancelUnbond() {} catch {}
    }

    function withdrawUnbonded(uint256 actorSeed) external useActor(actorSeed) {
        try ps.withdrawUnbonded() {} catch {}
    }

    function claimUsdt(uint256 actorSeed) external useActor(actorSeed) {
        try ps.claimUsdt() {} catch {}
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 21 days));
        _afterAction();
    }

    /**
     * Settle twice from identical state, once with a large bond landing in the
     * same block first. The participant leg must be identical.
     *
     * `bond` is permissionless, so the settler can inflate the pool from any
     * address inside the settlement block. If the eligible fraction is
     * measured against the live share count, that hands the difference to the
     * two fixed recipients: measured, an honest holder's 100,000 USDT leg
     * became 100. The settler does not receive it, but the settler is not
     * independent of the recipients.
     */
    function settleWithSandwich(uint256 grossSeed, uint256 amtSeed) external {
        uint256 gross = bound(grossSeed, 1e18, 5_000_000e18);
        uint64 epoch = ps.nextEpoch();
        // The honest bystander. actors[0] is the one doing the sandwiching, so
        // the property is measured on somebody who does nothing: whether a
        // holder who just sits there is worse off because somebody else acted
        // in the settlement block. Comparing the aggregate leg instead is too
        // strong, because a sandwicher removing ITSELF from the eligible pool
        // legitimately changes what the pool is owed.
        address bystander = actors[1];

        uint256 snap = vm.snapshotState();
        vm.startPrank(settler);
        bool cleanOk;
        try ps.settleEpoch(epoch, gross, 0, 0, 0) { cleanOk = true; } catch {}
        vm.stopPrank();
        uint256 cleanCredit = cleanOk ? ps.claimableOf(bystander) : 0;
        vm.revertToState(snap);

        // Two ways to move the eligible pool inside the block, both free.
        // Bonding inflates the total; requesting an unbond and immediately
        // cancelling removes a position from eligibleShares and puts it back
        // as new shares, which is the one the first version of this property
        // missed entirely because it only ever bonded.
        address whale = actors[0];
        if (amtSeed % 2 == 0) {
            uint256 bal = hcow.balanceOf(whale);
            if (bal > 0) {
                vm.startPrank(whale);
                try ps.bond(_amount(amtSeed, bal)) {} catch {}
                vm.stopPrank();
            }
        } else {
            uint256 owned = ps.bondedOf(whale);
            if (owned > 0) {
                vm.startPrank(whale);
                try ps.requestUnbond(owned) { try ps.cancelUnbond() {} catch {} } catch {}
                vm.stopPrank();
            }
        }
        inSettlement = true;
        vm.startPrank(settler);
        bool dirtyOk;
        try ps.settleEpoch(epoch, gross, 0, 0, 0) { dirtyOk = true; } catch {}
        vm.stopPrank();
        uint256 dirtyCredit = dirtyOk ? ps.claimableOf(bystander) : 0;

        // A few wei of slack, and the worst absolute drop recorded separately
        // so a real reduction is visible even if the tolerance were wrong.
        //
        // The share counts move by a wei when a position is burned with a
        // ceiling and re-minted with a floor, and every credit is a floored
        // product, so exact equality is not achievable and demanding it reports
        // rounding as an attack. Measured on the honest contract: one wei out
        // of eighty two million.
        if (cleanOk && dirtyOk && dirtyCredit < cleanCredit) {
            uint256 drop = cleanCredit - dirtyCredit;
            if (drop > ghostWorstBystanderDrop) ghostWorstBystanderDrop = drop;
            if (drop > 4) ghostDivisorMoved += 1;
        }
        _afterAction();
    }

    function settle(uint256 grossSeed, uint256 costSeed, uint256 opexSeed, uint256 ppmSeed) external {
        uint256 gross = bound(grossSeed, 0, 5_000_000e18);
        uint256 direct = bound(costSeed, 0, gross);
        uint256 net = gross - direct;
        uint256 opex = bound(opexSeed, 0, (net * 4000) / 10_000);
        // Deliberately allowed to exceed MAX_DEDUCT_PPM so the cap is exercised
        // rather than assumed. A settlement above the cap must revert; if it
        // does not, the ghost below records it.
        uint32 ppm = uint32(bound(ppmSeed, 0, 60_000));
        uint64 epoch = ps.nextEpoch();
        uint256 priceBefore = _price();

        inSettlement = true;
        vm.startPrank(settler);
        try ps.settleEpoch(epoch, gross, direct, opex, ppm) {
            ghostSettlements += 1;
            _checkPolicy(epoch, ppm, priceBefore);
        } catch {}
        vm.stopPrank();
        _afterAction();
    }

    function _checkPolicy(uint64 epoch, uint32 ppm, uint256 priceBefore) internal {
        if (ppm > ps.MAX_DEDUCT_PPM()) ghostRateCapBreaches += 1;

        HCOWProfitShare.Settlement memory st = ps.getSettlement(epoch);

        // Rule 6. Principal is only consumed by an epoch that actually pays
        // participants, and the test is on what reached them.
        if (st.hcowDeducted > 0 && st.participantsUsdt < ps.MIN_PARTICIPANT_USDT()) {
            ghostRule6Breaches += 1;
        }

        // A burn must move poolIndex, or a pending unbond sits through a
        // settlement it is never charged for.
        if (st.hcowDeducted > 0 && ps.poolIndex() >= lastPoolIndex) ghostIndexStalls += 1;
        lastPoolIndex = ps.poolIndex();

        // No single settlement may take more than MAX_DEDUCT_PPM of the pool.
        if (priceBefore > 0) {
            uint256 p = _price();
            if (p < priceBefore) {
                uint256 dropPpm = ((priceBefore - p) * 1_000_000) / priceBefore;
                if (dropPpm > ghostWorstSingleDropPpm) ghostWorstSingleDropPpm = dropPpm;
            }
        }

        // Quarantine. Anyone who bonded during this epoch must not have been
        // credited by it.
        for (uint256 i = 0; i < actors.length; ++i) {
            address who = actors[i];
            if (arrivedInEpoch[who] == epoch + 1) {
                if (ps.claimableOf(who) > claimableAtArrival[who]) ghostQuarantineBreaks += 1;
                arrivedInEpoch[who] = type(uint64).max;
            }
        }
    }
}
