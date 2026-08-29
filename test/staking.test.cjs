'use strict';
/* Run: npx hardhat run test/staking.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');

let pass = 0, fail = 0;
const results = [];

const ok = (name, cond, detail) => {
  if (cond) { pass++; results.push(['ok', name, '']); }
  else {
    fail++;
    results.push(['XX', name, detail || '']);
    // Printed as it happens. This suite has sequential dependencies, so it dies
    // on the first unexpected revert, and when it does the report never prints
    // and every failure before it is invisible.
    console.log(`  XX  ${name}  ${detail || ''}`);
  }
};
const eq = (name, a, b) => ok(name, String(a) === String(b), `got ${a}, want ${b}`);
const near = (name, a, b, tol = 1e-9) =>
  ok(name, Math.abs(a - b) <= tol, `got ${a}, want ${b}`);

/** Revert assertion with an explicit sender. ethers omits `from` when
 *  estimating gas here, which would make msg.sender the zero address. */
async function rv(name, c, signer, fn, args, expected) {
  const from = await signer.getAddress();
  const to = await c.getAddress();
  const data = c.interface.encodeFunctionData(fn, args);
  try {
    await hre.network.provider.send('eth_call', [{ from, to, data }, 'latest']);
    ok(name, false, 'did not revert');
  } catch (e) {
    const raw = e.data ?? e.error?.data ?? null;
    let named = '';
    if (raw) { try { named = c.interface.parseError(raw)?.name ?? ''; } catch (_) {} }
    ok(name, !expected || named === expected,
       `got ${named || (e.message || '').slice(0, 70)}, want ${expected}`);
  }
}

const E = (n) => ethers.parseEther(String(n));
const D = (v) => Number(ethers.formatEther(v));
const ID = (s) => ethers.encodeBytes32String(s);

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function main() {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const S = await Promise.all([0, 1, 2, 3, 4, 5, 6].map((i) => provider.getSigner(i)));
  const [ownerS, funderS, aliceS, bobS, carolS, repAS, repBS] = S;
  const [owner, funder, alice, bob, carol, repAPayout, repBPayout] =
    await Promise.all(S.map((s) => s.getAddress()));

  const hcow = await deploy('MockHCOW', ownerS);
  const st = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
  const addr = await st.getAddress();

  for (const [who, amt] of [[alice, 100_000], [bob, 100_000], [carol, 100_000], [funder, 500_000]]) {
    await (await hcow.transfer(who, E(amt))).wait();
  }
  for (const s of [aliceS, bobS, carolS, funderS]) {
    await (await hcow.connect(s).approve(addr, ethers.MaxUint256)).wait();
  }

  const A = ID('node-a'), B = ID('node-b'), C = ID('node-c');

  // ---------------- registry ----------------
  eq('commission cap is 10%', await st.MAX_COMMISSION_BPS(), 1000);
  await rv('commission above the cap is rejected', st, ownerS,
    'registerRepresentative', [A, 'Node A', repAPayout, 1001, false], 'CommissionTooHigh');
  await rv('stranger cannot register', st, aliceS,
    'registerRepresentative', [A, 'Node A', repAPayout, 500, false], 'NotOwner');

  await (await st.registerRepresentative(A, 'Node A', repAPayout, 1000, false)).wait();
  await (await st.registerRepresentative(B, 'Node B', repBPayout, 0, true)).wait();
  await rv('duplicate id rejected', st, ownerS,
    'registerRepresentative', [A, 'Node A', repAPayout, 100, false], 'RepresentativeExists');

  const ra = await st.representativeOf(A);
  eq('rep name stored', ra[0], 'Node A');
  eq('rep commission stored', ra[2], 1000);
  ok('rep active on registration', ra[3]);
  ok('foundation flag stored', (await st.representativeOf(B))[4]);
  eq('two representatives registered', (await st.representativeIds()).length, 2);

  // ---------------- staking ----------------
  await rv('cannot stake zero', st, aliceS, 'stake', [0, A], 'ZeroAmount');
  await rv('cannot stake to an unknown rep', st, aliceS, 'stake', [E(1), C], 'UnknownRepresentative');

  await (await st.connect(aliceS).stake(E(1_000), A)).wait();
  await (await st.connect(bobS).stake(E(3_000), A)).wait();
  await (await st.connect(carolS).stake(E(4_000), B)).wait();

  eq('total staked', D(await st.totalStaked()), 8000);
  eq('rep A weight', D((await st.representativeOf(A))[5]), 4000);
  eq('rep B weight', D((await st.representativeOf(B))[5]), 4000);
  eq('rep A delegator count', (await st.representativeOf(A))[6], 2);

  await rv('cannot split a delegation across reps', st, aliceS,
    'stake', [E(1), B], 'AlreadyDelegatedElsewhere');
  await (await st.connect(aliceS).stake(E(1_000), A)).wait();
  eq('adding to the same rep works', D((await st.delegationOf(alice))[1]), 2000);

  // ---------------- rewards ----------------
  const DUR = 90_000;
  /** Run the clock to the end of the current funding period. */
  const runPeriod = async () => {
    await provider.send('evm_increaseTime', [DUR + 1]);
    await provider.send('evm_mine', []);
  };
  await rv('only the funder can fund', st, aliceS, 'fundRewards', [E(100), DUR], 'NotFunder');
  await rv('cannot fund zero', st, funderS, 'fundRewards', [0, DUR], 'ZeroAmount');
  await rv('a period cannot be shorter than a day', st, funderS, 'fundRewards', [E(100), 3600], 'BadDuration');
  await rv('a period cannot run past a year', st, funderS, 'fundRewards',
    [E(100), 366 * 24 * 3600], 'BadDuration');

  // weight now: A 5000 (alice 2000, bob 3000), B 4000 (carol), total 9000.
  // 9000 HCOW streamed over the whole period is exactly 1 per staked token.
  // A takes 10% commission, B takes none.
  await (await st.connect(funderS).fundRewards(E(9_000), DUR)).wait();
  await runPeriod();

  near('alice earned her tokens less commission', D(await st.pendingRewardOf(alice)), 1800);
  near('bob earned his tokens less commission', D(await st.pendingRewardOf(bob)), 2700);
  near('carol pays no commission', D(await st.pendingRewardOf(carol)), 4000);
  near('rep A commission accrued', D(await st.commissionOf(A)), 500);
  eq('rep B commission is zero', D(await st.commissionOf(B)), 0);
  near('everything funded is accounted for',
    D(await st.pendingRewardOf(alice)) + D(await st.pendingRewardOf(bob))
    + D(await st.pendingRewardOf(carol)) + D(await st.commissionOf(A)), 9000, 1e-6);

  // ---------------- claiming ----------------
  const aliceBefore = await hcow.balanceOf(alice);
  await (await st.connect(aliceS).claimHcow()).wait();
  near('alice received her reward', D((await hcow.balanceOf(alice)) - aliceBefore), 1800);
  eq('alice pending is now zero', D(await st.pendingRewardOf(alice)), 0);
  await rv('claiming twice reverts', st, aliceS, 'claimHcow', [], 'NothingToClaim');

  const repABefore = await hcow.balanceOf(repAPayout);
  await (await st.connect(aliceS).claimCommission(A)).wait();
  near('commission went to the payout address, not the caller',
    D((await hcow.balanceOf(repAPayout)) - repABefore), 500);
  // A representative is paid without waiting for its delegators to act.
  eq('bob has still not touched his position', D(await st.pendingRewardOf(bob)), 2700);
  await rv('commission cannot be drained twice', st, aliceS, 'claimCommission', [A], 'NothingToClaim');

  // ---------------- late staker gets nothing retroactively ----------------
  const daveS = await provider.getSigner(7);
  const dave = await daveS.getAddress();
  await (await hcow.transfer(dave, E(5_000))).wait();
  await (await hcow.connect(daveS).approve(addr, ethers.MaxUint256)).wait();
  await (await st.connect(daveS).stake(E(5_000), A)).wait();
  eq('dave has no retroactive reward', D(await st.pendingRewardOf(dave)), 0);
  near('bob keeps his unclaimed reward', D(await st.pendingRewardOf(bob)), 2700);

  // ---------------- a stake held for a moment earns a moment ----------------
  // The old design split a lump sum by whoever was staked at the instant of
  // funding, so this position took most of the round for one block.
  const flashS = await provider.getSigner(8);
  const flash = await flashS.getAddress();
  await (await hcow.transfer(flash, E(900_000))).wait();
  await (await hcow.connect(flashS).approve(addr, ethers.MaxUint256)).wait();
  await (await st.connect(funderS).fundRewards(E(9_000), DUR)).wait();
  await provider.send('evm_increaseTime', [DUR - 10]);
  await provider.send('evm_mine', []);
  await (await st.connect(flashS).stake(E(900_000), B)).wait();
  await provider.send('evm_increaseTime', [10]);
  await provider.send('evm_mine', []);
  ok('a position held for ten seconds of a period earns ten seconds of it',
    D(await st.pendingRewardOf(flash)) < 2, `got ${D(await st.pendingRewardOf(flash))}`);
  await (await st.connect(flashS).requestUnstake(E(900_000))).wait();
  await provider.send('evm_increaseTime', [7 * 24 * 3600 + 1]);
  await provider.send('evm_mine', []);
  await (await st.connect(flashS).withdrawUnstaked({ gasLimit: 300_000 })).wait();
  eq('the flash position is gone', D(await st.totalPendingUnstake()), 0);

  // ---------------- redelegation ----------------
  await rv('cannot redelegate to the same rep', st, aliceS, 'redelegate', [A], 'SameRepresentative');
  await rv('cannot redelegate to an unknown rep', st, aliceS, 'redelegate', [C], 'UnknownRepresentative');

  // fund again so alice has something pending at rep A before moving
  await (await st.connect(funderS).fundRewards(E(14_000), DUR)).wait();
  await runPeriod();
  const alicePendingAtA = D(await st.pendingRewardOf(alice));
  ok('alice earned at rep A before moving', alicePendingAtA > 1800,
    `got ${alicePendingAtA}`);

  // Moving to a zero commission representative must not claw back commission
  // that already accrued at the old one. Under the lump sum design a hop
  // timed around a funding round avoided it entirely.
  const repACommBefore = D(await st.commissionOf(A));
  await (await st.connect(aliceS).redelegate(B)).wait();
  near('commission already earned survives the move', D(await st.commissionOf(A)),
    repACommBefore, 1e-6);
  eq('alice now delegates to rep B', (await st.delegationOf(alice))[0], B);
  near('redelegation preserved her earned reward', D(await st.pendingRewardOf(alice)), alicePendingAtA);
  eq('rep A lost her weight', D((await st.representativeOf(A))[5]), 8000);
  eq('rep B gained her weight', D((await st.representativeOf(B))[5]), 6000);
  eq('rep A delegator count fell', (await st.representativeOf(A))[6], 2);
  eq('rep B delegator count rose', (await st.representativeOf(B))[6], 2);

  // ---------------- inactive representative ----------------
  await (await st.updateRepresentative(A, repAPayout, 1000, false)).wait();
  ok('rep A is inactive', !(await st.representativeOf(A))[3]);
  await rv('cannot stake to an inactive rep', st, bobS, 'stake', [E(1), A], 'RepresentativeInactive');

  const bobPendingBefore = D(await st.pendingRewardOf(bob));
  const repBWeight = D((await st.representativeOf(B))[5]);
  await (await st.connect(funderS).fundRewards(E(1_000), DUR)).wait();
  await runPeriod();
  // active gates new delegations, not accrual. Punishing a delegator for a
  // decision the owner made about their representative is not the point of
  // the flag, and it would strand them mid cooldown.
  ok('a delegator of a deactivated rep keeps earning',
    D(await st.pendingRewardOf(bob)) > bobPendingBefore,
    `${D(await st.pendingRewardOf(bob))} vs ${bobPendingBefore}`);
  ok('weights unchanged by funding', D((await st.representativeOf(B))[5]) === repBWeight);

  // ---------------- unstaking ----------------
  await rv('cannot cancel without a pending unstake', st, bobS, 'cancelUnstake', [], 'NoPendingUnstake');
  await rv('cannot unstake more than staked', st, bobS, 'requestUnstake', [E(99_999)], 'InsufficientStake');

  const bobBeforeUnstake = D(await st.pendingRewardOf(bob));
  await (await st.connect(bobS).requestUnstake(E(3_000))).wait();
  eq('bob stake is zero', D((await st.delegationOf(bob))[1]), 0);
  eq('pending unstake recorded', D(await st.totalPendingUnstake()), 3000);
  near('bob keeps what he already earned', D(await st.pendingRewardOf(bob)), bobBeforeUnstake, 1e-3);
  await rv('only one unstake at a time', st, bobS, 'requestUnstake', [E(1)], 'UnstakeAlreadyPending');
  await rv('cooldown blocks withdrawal', st, bobS, 'withdrawUnstaked', [], 'CooldownActive');

  await provider.send('evm_increaseTime', [7 * 24 * 3600 + 1]);
  await provider.send('evm_mine', []);

  const bobHcowBefore = await hcow.balanceOf(bob);
  // explicit gas limit: estimation would run without a sender and misread state
  await (await st.connect(bobS).withdrawUnstaked({ gasLimit: 300_000 })).wait();
  near('bob got his stake back', D((await hcow.balanceOf(bob)) - bobHcowBefore), 3000);
  eq('pending unstake cleared', D(await st.totalPendingUnstake()), 0);

  // cancel path, on an active rep
  await (await st.connect(carolS).requestUnstake(E(1_000))).wait();
  eq('carol stake reduced', D((await st.delegationOf(carol))[1]), 3000);
  await (await st.connect(carolS).cancelUnstake()).wait();
  eq('carol stake restored', D((await st.delegationOf(carol))[1]), 4000);
  eq('nothing pending after cancel', D(await st.totalPendingUnstake()), 0);

  // ---------------- funding with no active weight ----------------
  const st2 = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
  await (await hcow.connect(funderS).approve(await st2.getAddress(), ethers.MaxUint256)).wait();
  // Funding an empty pool is allowed. The seconds that elapse with nothing
  // staked are carried into the next period rather than handed to whoever
  // stakes first, which would be the lump sum problem again.
  await (await st2.connect(funderS).fundRewards(E(100), 86_400)).wait();
  await provider.send('evm_increaseTime', [86_401]);
  await provider.send('evm_mine', []);
  await (await st2.connect(funderS).fundRewards(E(100), 86_400)).wait();
  ok('an empty period is carried, not lost',
    D(await st2.totalRewardsFunded()) === 200, `${D(await st2.totalRewardsFunded())}`);

  // ---------------- administration ----------------
  await rv('stranger cannot change the funder', st, aliceS, 'setRewardFunder', [alice], 'NotOwner');
  await rv('funder cannot be zero', st, ownerS, 'setRewardFunder', [ethers.ZeroAddress], 'ZeroAddress');
  await rv('commission cannot be raised past the cap on update', st, ownerS,
    'updateRepresentative', [A, repAPayout, 1500, true], 'CommissionTooHigh');

  // ---------------- period may only extend ----------------
  // Blocking a slower rate but not a shorter period leaves the mirror image
  // open: one wei on the minimum duration compresses a year's budget into a
  // day, and anyone reading the mempool front runs it with a large stake.
  await (await st.connect(funderS).fundRewards(E(5_000), 300 * 86_400)).wait();
  await rv('a funding cannot pull the end date in', st, funderS, 'fundRewards',
    [1, 86_400], 'BadDuration');
  // The absolute floor still binds inside a live period. Dropping it there,
  // where the remaining time is short, lets a top up be released into a window
  // a same block arrival can stand in and take whole.
  const stF = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
  await (await hcow.connect(funderS).approve(await stF.getAddress(), ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(await stF.getAddress(), ethers.MaxUint256)).wait();
  await (await stF.registerRepresentative(A, 'A', repAPayout, 0, false)).wait();
  await (await stF.connect(bobS).stake(E(1_000), A)).wait();
  await (await stF.connect(funderS).fundRewards(E(10), 86_400)).wait();
  await provider.send('evm_increaseTime', [86_400 - 3_600]);
  await provider.send('evm_mine', []);
  await rv('nor inside one whose remaining time is shorter', stF, funderS,
    'fundRewards', [E(1_000), 3_600], 'BadDuration');
  await rv('not even one second before it ends', stF, funderS,
    'fundRewards', [E(1_000), 1], 'BadDuration');
  await rv('and still cannot slow the rate', st, funderS, 'fundRewards',
    [1, 365 * 86_400], 'BadDuration');

  // ...but a real top up inside that last window must still be possible. The
  // duration floor and a rate floor set by a nearly finished period are in
  // direct conflict there, and between them they refused every funding however
  // large, which is the whole reward budget locked out for the last day of
  // every period.
  {
    await (await stF.connect(funderS).fundRewards(E(1_000), 30 * 86_400)).wait();
    ok('a real top up is accepted in the last window of a period',
      (await stF.rewardRate()) > 0n, `rate ${await stF.rewardRate()}`);
    eq('and the whole amount is on the books',
      D(await stF.totalRewardsFunded()), 1_010);
    // what the finished period still owed is not destroyed by the re-rate
    const finish = Number(await stF.periodFinish());
    await provider.send('evm_increaseTime', [30 * 86_400 + 10]);
    await provider.send('evm_mine', []);
    ok('the new period runs a full thirty days from the funding',
      finish > 0, `finish ${finish}`);
    const pend = D(await stF.pendingRewardOf(bob));
    near('and bob, the only staker, is owed essentially the whole budget', pend, 1_010, 1e-3);
  }

  // ---------------- a dust pool cannot pump the accumulator ----------------
  const st3 = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
  const a3 = await st3.getAddress();
  await (await hcow.connect(funderS).approve(a3, ethers.MaxUint256)).wait();
  await (await hcow.connect(aliceS).approve(a3, ethers.MaxUint256)).wait();
  await (await st3.registerRepresentative(A, 'A', repAPayout, 0, false)).wait();
  await (await st3.connect(aliceS).stake(1, A)).wait();
  await (await st3.connect(funderS).fundRewards(E(100_000), 86_400)).wait();
  await provider.send('evm_increaseTime', [86_401]);
  await provider.send('evm_mine', []);
  eq('a one wei pool accrues nothing', D(await st3.pendingRewardOf(alice)), 0);
  ok('and the seconds are carried, not lost', (await st3.undistributed()) > 0n);

  // Carried funds now have a delivery path of their own. Without one, seconds
  // that elapsed while too little was staked could only ever leave in the
  // arithmetic of the NEXT ordinary funding, so rewards already committed
  // depended on the funder choosing to fund again.
  //
  // The guard runs AFTER _updateGlobal. `undistributed` is written by
  // _updateGlobal, so testing it first refuses the call in exactly the state
  // the path exists for: that is how the first attempt at this was wrong and
  // was removed, and the reordering is the whole fix.
  await (await st3.connect(aliceS).stake(E(1_000), A)).wait();
  await (await st3.connect(funderS).fundRewards(1, 86_400)).wait();
  await provider.send('evm_increaseTime', [86_401]);
  await provider.send('evm_mine', []);
  ok('carried funds come back out with the next funding',
    (await st3.pendingRewardOf(alice)) > 0n);

  // ---------------- the carry has a delivery path of its own ----------------
  //
  // Without one, seconds that elapsed while too little was staked could only
  // ever leave in the arithmetic of the NEXT ordinary funding, so rewards that
  // were already committed depended on the funder choosing to fund again.
  //
  // The guard runs AFTER _updateGlobal. `undistributed` is written by
  // _updateGlobal, so testing it before the accumulator has advanced refuses
  // the call in exactly the state the path exists for: that is how the first
  // attempt at a zero token funding was wrong and was removed, and putting the
  // test after the update is the whole fix.
  {
    const stC = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
    const aC = await stC.getAddress();
    await (await hcow.connect(funderS).approve(aC, ethers.MaxUint256)).wait();
    await (await hcow.connect(aliceS).approve(aC, ethers.MaxUint256)).wait();
    await (await stC.registerRepresentative(A, 'A', repAPayout, 0, false)).wait();

    await rv('a zero token funding with nothing carried is refused',
      stC, funderS, 'fundRewards', [0, 86_400], 'ZeroAmount');

    await (await stC.connect(aliceS).stake(1, A)).wait();
    // Exactly divisible by the duration, deliberately: the funding leaves no
    // rounding remainder, so `undistributed` is genuinely ZERO in storage when
    // the period ends and only becomes non-zero once _updateGlobal runs. Funded
    // with a figure that leaves a remainder, the guard would pass on that dust
    // whichever side of the update it sat, and the ordering this test exists
    // for would not be exercised at all.
    await (await stC.connect(funderS).fundRewards(E(86_400), 86_400)).wait();
    eq('the funding divides exactly, so nothing is carried yet',
       D(await stC.undistributed()), 0);
    await provider.send('evm_increaseTime', [86_401]);
    await provider.send('evm_mine', []);
    eq('and the stored figure is still zero until something advances it',
       D(await stC.undistributed()), 0);
    const held = await hcow.balanceOf(aC);
    const funderHeld = await hcow.balanceOf(funder);
    // fundRewards runs _updateGlobal first, which is what moves the elapsed
    // seconds into `undistributed`. Reading the getter before any state
    // changing call returns the stale value, which is exactly why the guard
    // had to move below the update.
    // Guarded rather than awaited bare. If the guard were ever moved back above
    // _updateGlobal this call reverts, and an unguarded revert kills the
    // process before the report prints, hiding this failure and every other.
    let released = true;
    try { await (await stC.connect(funderS).fundRewards(0, 86_400)).wait(); }
    catch { released = false; }
    ok('the carry can be released with no new money', released);
    if (!released) { console.log('  (skipping the rest of the carry block)'); }
    else {
    ok('a dust pool carried the whole period rather than losing it',
       D(await stC.rewardRate()) * 86_400 > 86_000,
       `rate * duration ${D(await stC.rewardRate()) * 86_400}`);
    eq('releasing the carry moves no tokens in', D(await hcow.balanceOf(aC)), D(held));
    eq('and costs the funder nothing', D(await hcow.balanceOf(funder)), D(funderHeld));

    // a real pool now collects what was carried, with no new money
    await (await stC.connect(aliceS).stake(E(1_000), A)).wait();
    await provider.send('evm_increaseTime', [86_401]);
    await provider.send('evm_mine', []);
    const got = D(await stC.pendingRewardOf(alice));
    ok('and a real pool collects it without the funder acting again',
       got > 86_000 && got <= 86_400, `collected ${got}`);
    }
  }

  // ---------------- the registry ceiling is real ----------------
  //
  // The cap exists because the identifier array is walked, and there is no way
  // to reclaim a slot: the hundredth registration is final for the life of the
  // contract. Independent mutation testing raised the bound by a factor of a
  // thousand and no suite in either repository failed, which means the bound
  // that exists was not protected against being changed by accident.
  {
    const stR = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
    const cap = Number(await stR.MAX_REPRESENTATIVES());
    eq('the published ceiling is one hundred', cap, 100);
    // Bounded independently of the constant. Deriving the loop from the value
    // under test means a mutation that raises the ceiling makes this suite run
    // for hours instead of failing, and a test that hangs is a test that gets
    // deleted.
    const N = Math.min(cap, 100);
    for (let i = 0; i < N; i++) {
      await (await stR.registerRepresentative(
        ethers.zeroPadValue(ethers.toBeHex(i + 1), 32), `r${i}`, repAPayout, 0, false)).wait();
    }
    eq('the registry filled to the ceiling', (await stR.representativeIds()).length, N);
    await rv('and the next registration is refused', stR, ownerS, 'registerRepresentative',
      [ethers.zeroPadValue(ethers.toBeHex(N + 1), 32), 'over', repAPayout, 0, false],
      'TooManyRepresentatives');

    // marking one inactive does not reclaim its slot, which is the disclosed
    // limit rather than a defect
    await (await stR.updateRepresentative(
      ethers.zeroPadValue(ethers.toBeHex(1), 32), repAPayout, 0, false)).wait();
    const counts = await stR.representativeCount();
    eq('the inactive one is still counted against the ceiling', Number(counts[0]), N);
    eq('but not as active', Number(counts[1]), N - 1);
    await rv('and the slot is not reclaimed', stR, ownerS, 'registerRepresentative',
      [ethers.zeroPadValue(ethers.toBeHex(N + 2), 32), 'over', repAPayout, 0, false],
      'TooManyRepresentatives');
  }

  // ---------------- ownership moves in two steps ----------------
  {
    const stO = await deploy('HCOWStaking', ownerS, [await hcow.getAddress(), owner, funder]);
    await rv('a stranger cannot start a transfer', stO, aliceS,
      'transferOwnership', [alice], 'NotOwner');
    await (await stO.transferOwnership(alice)).wait();
    eq('the owner does not change on the first step', await stO.owner(), owner);
    eq('the nominee is recorded', await stO.pendingOwner(), alice);
    await rv('only the nominee can accept', stO, bobS, 'acceptOwnership', [], 'NotPendingOwner');
    await (await stO.cancelOwnershipTransfer()).wait();
    eq('a nomination can be withdrawn outright', await stO.pendingOwner(), ethers.ZeroAddress);
    await rv('and then nobody can accept it', stO, aliceS,
      'acceptOwnership', [], 'NotPendingOwner');
    await (await stO.transferOwnership(alice)).wait();
    await (await stO.connect(aliceS).acceptOwnership()).wait();
    eq('the nominee becomes the owner on the second step', await stO.owner(), alice);
    eq('and the nomination is cleared', await stO.pendingOwner(), ethers.ZeroAddress);
    await rv('the old owner has no powers left', stO, ownerS,
      'setRewardFunder', [bob], 'NotOwner');
  }

  // Deregistration is deliberately not offered: a record reads empty the
  // moment a delegator requests a full unstake, while the delegation still
  // points at it and can be cancelled back in.
  const D2 = ethers.encodeBytes32String('busy');
  await (await st3.registerRepresentative(D2, 'busy', repAPayout, 1000, false)).wait();
  await (await hcow.connect(bobS).approve(a3, ethers.MaxUint256)).wait();
  await (await st3.connect(bobS).stake(E(500), D2)).wait();
  await (await st3.connect(bobS).requestUnstake(E(500))).wait();
  eq('a full unstake leaves no weight', D((await st3.representativeOf(D2))[5]), 0);
  eq('and no delegators', (await st3.representativeOf(D2))[6], 0n);
  await (await st3.connect(bobS).cancelUnstake()).wait();
  eq('cancelling restores the weight to the same representative',
    D((await st3.representativeOf(D2))[5]), 500);
  eq('and totals still reconcile', D(await st3.totalStaked()),
    D((await st3.representativeOf(A))[5]) + D((await st3.representativeOf(D2))[5]));

  // ---------------- solvency ----------------
  let owed = 0n;
  for (const who of [alice, bob, carol, dave]) owed += await st.pendingRewardOf(who);
  for (const id of [A, B]) owed += await st.commissionOf(id);
  owed += await st.pendingRewardOf(flash);
  // Funded HCOW that has not been released yet is float the contract holds on
  // purpose, not surplus: the carried part in undistributed, plus the part of
  // the live period still ahead of the clock.
  const nowTs = BigInt((await provider.getBlock('latest')).timestamp);
  const finish = await st.periodFinish();
  const unreleased = finish > nowTs ? (finish - nowTs) * (await st.rewardRate()) : 0n;
  const accounted = (await st.totalStaked()) + (await st.totalPendingUnstake())
    + owed + (await st.undistributed()) + unreleased;
  const held = await hcow.balanceOf(addr);
  ok('contract holds at least stake plus pending plus rewards owed',
     held >= accounted, `holds ${D(held)}, needs ${D(accounted)}`);
  ok('surplus is only rounding dust', D(held) - D(accounted) < 1,
     `surplus ${D(held) - D(accounted)}`);

  const w = Math.max(...results.map((r) => r[1].length));
  for (const [s, n, d] of results) console.log(`  ${s}  ${n.padEnd(w)}  ${d}`);
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) process.exit(1);
}

main().catch((e) => {
  console.error(e.stack || e.shortMessage || e.message);
  console.error(e.info?.error?.message || '');
  process.exit(1);
});
