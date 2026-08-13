'use strict';
/* Run: npx hardhat run test/staking.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');

let pass = 0, fail = 0;
const results = [];

const ok = (name, cond, detail) => {
  if (cond) { pass++; results.push(['ok', name, '']); }
  else { fail++; results.push(['XX', name, detail || '']); }
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
  await rv('only the funder can fund', st, aliceS, 'fundRewards', [E(100)], 'NotFunder');
  await rv('cannot fund zero', st, funderS, 'fundRewards', [0], 'ZeroAmount');

  // weight now: A 5000, B 4000, total 9000
  // fund 9000 -> A gets 5000, B gets 4000
  // A commission 10% = 500, delegators 4500  (alice 2/5, bob 3/5)
  // B commission 0%,        delegators 4000  (carol all)
  await (await st.connect(funderS).fundRewards(E(9_000))).wait();

  near('alice reward is her share of rep A', D(await st.pendingRewardOf(alice)), 1800);
  near('bob reward is his share of rep A', D(await st.pendingRewardOf(bob)), 2700);
  near('carol takes all of rep B', D(await st.pendingRewardOf(carol)), 4000);
  eq('rep A commission accrued', D((await st.representativeOf(A))[7]), 500);
  eq('rep B commission is zero', D((await st.representativeOf(B))[7]), 0);
  near('nothing unaccounted', D(await st.totalRewardsOwed()), 9000);

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
  await rv('commission cannot be drained twice', st, aliceS, 'claimCommission', [A], 'NothingToClaim');

  // ---------------- late staker gets nothing retroactively ----------------
  const daveS = await provider.getSigner(7);
  const dave = await daveS.getAddress();
  await (await hcow.transfer(dave, E(5_000))).wait();
  await (await hcow.connect(daveS).approve(addr, ethers.MaxUint256)).wait();
  await (await st.connect(daveS).stake(E(5_000), A)).wait();
  eq('dave has no retroactive reward', D(await st.pendingRewardOf(dave)), 0);
  near('bob keeps his unclaimed reward', D(await st.pendingRewardOf(bob)), 2700);

  // ---------------- redelegation ----------------
  await rv('cannot redelegate to the same rep', st, aliceS, 'redelegate', [A], 'SameRepresentative');
  await rv('cannot redelegate to an unknown rep', st, aliceS, 'redelegate', [C], 'UnknownRepresentative');

  // fund again so alice has something pending at rep A before moving
  // weight: A 10000 (alice 2000, bob 3000, dave 5000), B 4000, total 14000
  await (await st.connect(funderS).fundRewards(E(14_000))).wait();
  const alicePendingAtA = D(await st.pendingRewardOf(alice));
  near('alice earned at rep A before moving', alicePendingAtA, 1800);

  await (await st.connect(aliceS).redelegate(B)).wait();
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
  await (await st.connect(funderS).fundRewards(E(1_000))).wait();
  near('an inactive rep receives nothing new', D(await st.pendingRewardOf(bob)), bobPendingBefore);
  near('the active rep took the whole round',
    D(await st.pendingRewardOf(carol)) + D(await st.pendingRewardOf(alice)),
    4000 + 4000 + alicePendingAtA + 1000, 1e-6);
  ok('weights unchanged by funding', D((await st.representativeOf(B))[5]) === repBWeight);

  // ---------------- unstaking ----------------
  await rv('cannot cancel without a pending unstake', st, bobS, 'cancelUnstake', [], 'NoPendingUnstake');
  await rv('cannot unstake more than staked', st, bobS, 'requestUnstake', [E(99_999)], 'InsufficientStake');

  await (await st.connect(bobS).requestUnstake(E(3_000))).wait();
  eq('bob stake is zero', D((await st.delegationOf(bob))[1]), 0);
  eq('pending unstake recorded', D(await st.totalPendingUnstake()), 3000);
  near('bob keeps what he already earned', D(await st.pendingRewardOf(bob)), bobPendingBefore);
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
  await rv('cannot fund when nobody is staked', st2, funderS, 'fundRewards', [E(100)], 'NoActiveWeight');

  // ---------------- administration ----------------
  await rv('stranger cannot change the funder', st, aliceS, 'setRewardFunder', [alice], 'NotOwner');
  await rv('funder cannot be zero', st, ownerS, 'setRewardFunder', [ethers.ZeroAddress], 'ZeroAddress');
  await rv('commission cannot be raised past the cap on update', st, ownerS,
    'updateRepresentative', [A, repAPayout, 1500, true], 'CommissionTooHigh');

  // ---------------- solvency ----------------
  let owed = 0n;
  for (const who of [alice, bob, carol, dave]) owed += await st.pendingRewardOf(who);
  for (const id of [A, B]) owed += (await st.representativeOf(id))[7];
  const accounted = (await st.totalStaked()) + (await st.totalPendingUnstake()) + owed;
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
  console.error(e.shortMessage || e.message);
  console.error(e.info?.error?.message || '');
  process.exit(1);
});
