'use strict';
/**
 * HCOWStaking - randomized invariant (property) test.
 *
 * Run: npx hardhat run test/invariant.staking.cjs
 *
 * Same method as invariant.profitshare.cjs. Random sequences of real user
 * actions, with a set of properties re-checked after every single operation.
 * The delegated-staking accounting is the risk surface here: one accumulator
 * per representative, commission taken off the top, and stake that can move
 * between representatives mid-stream.
 */

const hre = require('hardhat');
const { ethers } = require('ethers');

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const E = (n) => ethers.parseEther(String(n));
const ID = (s) => ethers.id(s);

let violations = [];
let opsRun = 0;
const cover = {};
const bump = (k) => { cover[k] = (cover[k] || 0) + 1; };

function must(seed, op, name, cond, detail) {
  if (!cond) violations.push({ seed, op, name, detail: detail || '' });
}

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function runSeed(seed, opCount) {
  const rnd = mulberry32(seed);
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));

  const provider = new ethers.BrowserProvider(hre.network.provider);
  const all = await provider.listAccounts();

  const deployer = await provider.getSigner(0);
  const funder = await provider.getSigner(1);
  const actors = [];
  for (let i = 4; i < Math.min(10, all.length); i++) actors.push(await provider.getSigner(i));

  const hcow = await deploy('MockHCOW', deployer);
  const st = await deploy('HCOWStaking', deployer, [
    await hcow.getAddress(),
    await deployer.getAddress(),
    await funder.getAddress(),
  ]);
  const stAddr = await st.getAddress();

  // Three representatives with different commissions, one of them foundation.
  const REPS = [ID('rep.alpha'), ID('rep.beta'), ID('rep.gamma')];
  const payouts = [await provider.getSigner(2), await provider.getSigner(3), await provider.getSigner(2)];
  for (let i = 0; i < REPS.length; i++) {
    await (await st.connect(deployer).registerRepresentative(
      REPS[i], `rep${i}`, await payouts[i].getAddress(), [0, 500, 1000][i], i === 0
    )).wait();
  }

  for (const a of actors) {
    await (await hcow.connect(deployer).transfer(await a.getAddress(), E(1_000_000))).wait();
    await (await hcow.connect(a).approve(stAddr, ethers.MaxUint256)).wait();
  }
  await (await hcow.connect(deployer).transfer(await funder.getAddress(), E(20_000_000))).wait();
  await (await hcow.connect(funder).approve(stAddr, ethers.MaxUint256)).wait();

  let lastFunded = 0n;
  const lastAcc = {};

  for (let op = 0; op < opCount; op++) {
    const action = pick([
      'stake', 'stake', 'stake',
      'redelegate',
      'requestUnstake', 'requestUnstake',
      'cancelUnstake',
      'withdrawUnstaked',
      'claimHcow', 'claimHcow',
      'claimCommission',
      'fundRewards', 'fundRewards',
      'updateRep',
      'warp',
    ]);
    const actor = pick(actors);

    try {
      if (action === 'stake') {
        await (await st.connect(actor).stake(E(int(1, 30_000)), pick(REPS))).wait();
      } else if (action === 'redelegate') {
        await (await st.connect(actor).redelegate(pick(REPS))).wait();
      } else if (action === 'requestUnstake') {
        const d = await st.delegationOf(await actor.getAddress());
        if (d.stakedAmount > 0n) {
          await (await st.connect(actor).requestUnstake(
            (d.stakedAmount * BigInt(int(1, 100))) / 100n)).wait();
        }
      } else if (action === 'cancelUnstake') {
        await (await st.connect(actor).cancelUnstake()).wait();
      } else if (action === 'withdrawUnstaked') {
        await (await st.connect(actor).withdrawUnstaked()).wait();
      } else if (action === 'claimHcow') {
        await (await st.connect(actor).claimHcow()).wait();
      } else if (action === 'claimCommission') {
        await (await st.connect(deployer).claimCommission(pick(REPS))).wait();
      } else if (action === 'fundRewards') {
        // Rewards stream over a period now, so a funding carries a duration
        // and the clock has to move for anything to accrue.
        // A funding may add tokens or add time, never redistribute what is
        // already promised, so a live period needs a duration that reaches at
        // least as far as the one it replaces.
        const finish = Number(await st.periodFinish());
        const nowT = Number((await hre.ethers.provider.getBlock('latest')).timestamp);
        const minDur = finish > nowT ? finish - nowT : 0;
        const dur = Math.min(365 * 86400, Math.max(86400, minDur + int(0, 30) * 86400));
        await (await st.connect(funder).fundRewards(E(int(1, 20_000)), dur)).wait();
      } else if (action === 'updateRep') {
        const id = pick(REPS);
        const r = await st.representativeOf(id);
        await (await st.connect(deployer).updateRepresentative(
          id, r.payout, int(0, 1000), rnd() < 0.8)).wait();
      } else if (action === 'warp') {
        await hre.network.provider.send('evm_increaseTime', [int(1, 10) * 86400]);
        await hre.network.provider.send('evm_mine', []);
      }
      bump(action + ':ok');
    } catch (_) {
      bump(action + ':revert');
    }

    opsRun++;

    const totalStaked = await st.totalStaked();
    const totalPending = await st.totalPendingUnstake();
    const owed = await st.totalRewardsOwed();
    const funded = await st.totalRewardsFunded();
    const bal = await hcow.balanceOf(stAddr);

    let sumStaked = 0n;
    let sumPending = 0n;
    let sumPendingReward = 0n;
    for (const a of actors) {
      const addr = await a.getAddress();
      const d = await st.delegationOf(addr);
      sumStaked += d.stakedAmount;
      sumPending += d.pendingUnstake;
      sumPendingReward += await st.pendingRewardOf(addr);
      // S7: an unstake request must always carry a ready time.
      must(seed, op, 'S7 pendingUnstake implies readyAt',
        !(d.pendingUnstake > 0n && d.unstakeReadyAt === 0n),
        `${addr} pending=${d.pendingUnstake}`);
    }

    let sumRepDelegated = 0n;
    let sumCommission = 0n;
    for (const id of REPS) {
      const r = await st.representativeOf(id);
      sumRepDelegated += r.totalDelegated;
      sumCommission += await st.commissionOf(id);
      // S6: commission can never be configured above the hard cap.
      must(seed, op, 'S6 commission within cap', r.commissionBps <= 1000n,
        `bps=${r.commissionBps}`);
    }

    // S1  SOLVENCY. Principal, reserved unstake, unclaimed rewards and accrued
    //     commission together can never exceed the HCOW actually held.
    const obligations = totalStaked + totalPending + sumPendingReward + sumCommission;
    must(seed, op, 'S1 HCOW solvency', obligations <= bal,
      `owed=${obligations} held=${bal}`);

    // S2  Stake conservation across accounts.
    must(seed, op, 'S2 stake conservation', sumStaked === totalStaked,
      `sum=${sumStaked} total=${totalStaked}`);

    // S3  Stake conservation across representatives.
    must(seed, op, 'S3 rep delegation conservation', sumRepDelegated === totalStaked,
      `reps=${sumRepDelegated} total=${totalStaked}`);

    // S4  Rewards owed can never exceed rewards actually funded.
    must(seed, op, 'S4 owed <= funded', owed <= funded,
      `owed=${owed} funded=${funded}`);

    // S5  Funded total never moves backwards.
    must(seed, op, 'S5 totalRewardsFunded monotonic', funded >= lastFunded);

    // S8  Reported pending unstake equals the reserve.
    must(seed, op, 'S8 pending reserve exact', sumPending === totalPending,
      `sum=${sumPending} total=${totalPending}`);

    // S9  No reward creation: what accounts can claim is covered by what is owed.
    // Each account's credit is a difference of two independently floored
    // figures, so the sum of the views can sit up to one wei per delegator
    // above the reserve, which is a single exact figure. Solvency (S1) is the
    // property that matters and is checked against the real token balance;
    // this one is checked with that slack made explicit rather than hidden.
    must(seed, op, 'S9 pendingReward <= totalRewardsOwed',
      sumPendingReward <= owed + BigInt(actors.length),
      `pending=${sumPendingReward} owed=${owed}`);

    lastFunded = funded;
  }
}

(async () => {
  const SEEDS = [1, 7, 42, 1337, 20260818, 99991, 5150, 8675309];
  const OPS = Number(process.env.INV_OPS || 220);

  console.log(`HCOWStaking invariant run: ${SEEDS.length} seeds x ${OPS} ops`);
  for (const s of SEEDS) {
    await hre.network.provider.send('hardhat_reset', []);
    process.stdout.write(`  seed ${String(s).padStart(9)} ... `);
    const before = violations.length;
    await runSeed(s, OPS);
    console.log(violations.length === before ? 'clean' : `${violations.length - before} VIOLATIONS`);
  }

  console.log(`\noperations executed: ${opsRun}`);
  console.log('coverage:');
  for (const k of Object.keys(cover).sort()) console.log(`  ${k.padEnd(26)} ${cover[k]}`);

  if (violations.length === 0) { console.log('all invariants held'); process.exit(0); }
  const byName = {};
  for (const v of violations) (byName[v.name] ||= []).push(v);
  console.log(`\n${violations.length} violation(s):`);
  for (const [name, list] of Object.entries(byName)) {
    console.log(`\n  ${name}  x${list.length}`);
    console.log(`    first: seed=${list[0].seed} op=${list[0].op} ${list[0].detail}`);
  }
  process.exit(1);
})();
