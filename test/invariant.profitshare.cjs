'use strict';
/**
 * HCOWProfitShare - randomized invariant (property) test.
 *
 * Run: npx hardhat run test/invariant.profitshare.cjs
 *
 * Unit tests check that a known input produces a known output. This does the
 * opposite: it drives the contract with long random sequences of real user
 * actions and asserts, after every single one, a set of properties that must
 * hold no matter what happened. That is the class of test that finds
 * accounting bugs, which is where the risk in this contract actually lives.
 *
 * The RNG is seeded, so any failure is reproducible: the seed and the exact
 * operation index are printed.
 */

const hre = require('hardhat');
const { ethers } = require('ethers');

// ---------------------------------------------------------------- seeded RNG
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

// --------------------------------------------------------------- test runner
let violations = [];
let opsRun = 0;
const cover = {};
const bump = (k)=>{cover[k]=(cover[k]||0)+1;};

function must(seed, op, name, cond, detail) {
  if (!cond) {
    violations.push({ seed, op, name, detail: detail || '' });
  }
}

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

// ------------------------------------------------------------------ scenario
async function runSeed(seed, opCount) {
  const rnd = mulberry32(seed);
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));

  const provider = new ethers.BrowserProvider(hre.network.provider);
  const all = await provider.listAccounts();

  const deployer = await provider.getSigner(0);
  const settler = await provider.getSigner(1);
  const gameCo = await provider.getSigner(2);
  const team = await provider.getSigner(3);
  const actors = [];
  for (let i = 4; i < Math.min(10, all.length); i++) actors.push(await provider.getSigner(i));

  const hcow = await deploy('MockHCOW', deployer);
  const usdt = await deploy('MockUSDT', deployer);
  const ps = await deploy('HCOWProfitShare', deployer, [
    await hcow.getAddress(),
    await usdt.getAddress(),
    await deployer.getAddress(),
    await settler.getAddress(),
    await gameCo.getAddress(),
    await team.getAddress(),
  ]);
  const psAddr = await ps.getAddress();

  // Fund actors with HCOW and pre-approve. Fund the settler with USDT.
  for (const a of actors) {
    await (await hcow.connect(deployer).transfer(await a.getAddress(), E(1_000_000))).wait();
    await (await hcow.connect(a).approve(psAddr, ethers.MaxUint256)).wait();
  }
  await (await usdt.connect(deployer).mint(await settler.getAddress(), E(50_000_000))).wait();
  await (await usdt.connect(settler).approve(psAddr, ethers.MaxUint256)).wait();

  // Running expectations the contract must never contradict.
  let lastAccUsdt = 0n;
  let lastAccDeducted = 0n;
  let lastPoolIndex = (1n << 60n) * (1n << 60n);
  let lastDistributed = 0n;
  let lastDeducted = 0n;
  // Every USDT the settler has actually deposited for participants.
  let creditedToParticipants = 0n;

  for (let op = 0; op < opCount; op++) {
    const action = pick([
      'bond', 'bond', 'bond',
      'requestUnbond', 'requestUnbond',
      'cancelUnbond',
      'withdrawUnbonded',
      'claimUsdt', 'claimUsdt',
      'settle', 'settle',
      'dodge',
      'warp',
    ]);
    const actor = pick(actors);

    try {
      if (action === 'bond') {
        await (await ps.connect(actor).bond(E(int(1, 50_000)))).wait();
      } else if (action === 'requestUnbond') {
        const owned = await ps.bondedOf(await actor.getAddress());
        if (owned > 0n) {
          const frac = BigInt(int(1, 100));
          await (await ps.connect(actor).requestUnbond((owned * frac) / 100n)).wait();
        }
      } else if (action === 'cancelUnbond') {
        await (await ps.connect(actor).cancelUnbond()).wait();
      } else if (action === 'withdrawUnbonded') {
        await (await ps.connect(actor).withdrawUnbonded()).wait();
      } else if (action === 'claimUsdt') {
        await (await ps.connect(actor).claimUsdt()).wait();
      } else if (action === 'settle') {
        const epoch = await ps.nextEpoch();
        const gross = E(int(0, 100_000));
        const direct = (gross * BigInt(int(0, 40))) / 100n;
        const net = gross - direct;
        // Stay at or under the cap most of the time, breach it sometimes so
        // the refusal path is exercised too.
        const opexBps = rnd() < 0.15 ? int(4001, 9000) : int(0, 4000);
        let opex = (net * BigInt(opexBps)) / 10_000n;
        // Dust profit with a maximum deduction. This is the shape that buys a
        // full size burn for a payout that rounds to nothing, and uniform
        // sampling never generates it.
        const dustProfit = rnd() < 0.1 && net > 0n;
        if (dustProfit) opex = net - 1n;
        const profit = net - opex;
        // Sometimes exceed the rate cap so the refusal path is exercised.
        const ppm = profit > 0n && rnd() < 0.6
          ? (rnd() < 0.1 ? int(20_001, 60_000) : int(1, 20_000))
          : 0;
        // Epochs have a minimum length now, so move the clock before settling.
        await hre.network.provider.send('evm_increaseTime', [31 * 86_400]);
        await hre.network.provider.send('evm_mine', []);
        await (await ps.connect(settler).settleEpoch(epoch, gross, direct, opex, ppm)).wait();
        const s = await ps.getSettlement(epoch);
        creditedToParticipants += s.participantsUsdt;
      } else if (action === 'dodge') {
        // requestUnbond -> settle -> cancelUnbond by the same actor, in order.
        // Independent random actions never produce this triple, and it is the
        // sequence that used to make the deduction optional.
        const addr = await actor.getAddress();
        const owned = await ps.bondedOf(addr);
        if (owned > 0n) {
          await (await ps.connect(actor).requestUnbond(owned)).wait();
          const epoch = await ps.nextEpoch();
          const gross = E(int(1, 50_000));
          const opex = (gross * BigInt(int(0, 4000))) / 10_000n;
          await hre.network.provider.send('evm_increaseTime', [31 * 86_400]);
          await hre.network.provider.send('evm_mine', []);
          await (await ps.connect(settler).settleEpoch(epoch, gross, 0n, opex, 20_000)).wait();
          creditedToParticipants += (await ps.getSettlement(epoch)).participantsUsdt;
          if (rnd() < 0.5) {
            await (await ps.connect(actor).cancelUnbond()).wait();
          } else {
            await hre.network.provider.send('evm_increaseTime', [7 * 86400 + 1]);
            await hre.network.provider.send('evm_mine', []);
            await (await ps.connect(actor).withdrawUnbonded({ gasLimit: 400_000 })).wait();
          }
        }
      } else if (action === 'warp') {
        await hre.network.provider.send('evm_increaseTime', [int(1, 10) * (rnd() < 0.5 ? 3600 : 86400)]);
        await hre.network.provider.send('evm_mine', []);
      }
      bump(action + ':ok');
    } catch (_) {
      // A revert is a legitimate outcome. The invariants below must still hold.
      bump(action + ':revert');
    }

    opsRun++;

    // ------------------------------------------------------------ invariants
    const totalShares = await ps.totalShares();
    const totalBonded = await ps.totalBondedHcow();
    const totalPending = await ps.totalPendingUnbond();
    const accUsdt = await ps.accUsdtPerShare();
    const accDed = await ps.accDeductedPerShare();
    const pCount = await ps.participantCount();
    const distributed = await ps.totalUsdtDistributed();
    const deducted = await ps.totalHcowDeducted();

    const usdtBal = await usdt.balanceOf(psAddr);
    const hcowBal = await hcow.balanceOf(psAddr);

    let sumShares = 0n;
    let sumClaimable = 0n;
    let sumBondedOf = 0n;
    let sumPending = 0n;
    let sumLifetimeClaimed = 0n;
    let holders = 0n;

    for (const a of actors) {
      const addr = await a.getAddress();
      const acct = await ps.accountOf(addr);
      sumShares += acct.shares;
      sumPending += acct.pendingUnbond;
      sumBondedOf += acct.bondedHcow;
      sumClaimable += await ps.claimableOf(addr);
      const lt = await ps.lifetimeOf(addr);
      sumLifetimeClaimed += lt.claimedUsdt;
      if (acct.shares > 0n) holders += 1n;
      // I9: a pending unbond must always carry a ready time.
      must(seed, op, 'I9 pendingUnbond implies unbondReadyAt',
        !(acct.pendingUnbond > 0n && acct.unbondReadyAt === 0n),
        `${addr} pending=${acct.pendingUnbond} readyAt=${acct.unbondReadyAt}`);
    }

    // I1  SOLVENCY. The contract can never owe more USDT than it holds.
    must(seed, op, 'I1 USDT solvency', sumClaimable <= usdtBal,
      `owed=${sumClaimable} held=${usdtBal}`);

    // I2  Share conservation.
    must(seed, op, 'I2 share conservation', sumShares === totalShares,
      `sum=${sumShares} total=${totalShares}`);

    // I3  HCOW backing. Bonded plus reserved can never exceed what is held.
    must(seed, op, 'I3 HCOW backing', totalBonded + totalPending <= hcowBal,
      `need=${totalBonded + totalPending} held=${hcowBal}`);

    // I4  Reward accumulator never decreases.
    must(seed, op, 'I4 accUsdtPerShare monotonic', accUsdt >= lastAccUsdt,
      `${accUsdt} < ${lastAccUsdt}`);

    // I5  Deduction accumulator never decreases.
    must(seed, op, 'I5 accDeductedPerShare monotonic', accDed >= lastAccDeducted,
      `${accDed} < ${lastAccDeducted}`);

    // I6  participantCount matches reality.
    must(seed, op, 'I6 participantCount exact', pCount === holders,
      `count=${pCount} actual=${holders}`);

    // I7  Per-account bonded view never over-reports the pool.
    must(seed, op, 'I7 sum(bondedOf) <= totalBonded', sumBondedOf <= totalBonded,
      `sum=${sumBondedOf} total=${totalBonded}`);

    // I8  An empty share pool must mean an empty bonded pool. If this ever
    //     fails, deduction can divide by zero and stray HCOW becomes unowned.
    must(seed, op, 'I8 no shares implies no bonded',
      !(totalShares === 0n && totalBonded > 0n),
      `shares=0 bonded=${totalBonded}`);

    // I10 Public totals never move backwards.
    must(seed, op, 'I10 totalUsdtDistributed monotonic', distributed >= lastDistributed);
    must(seed, op, 'I11 totalHcowDeducted monotonic', deducted >= lastDeducted);

    // I12 No money creation. Everything claimed plus everything still owed
    //     can never exceed what was actually credited to participants.
    must(seed, op, 'I12 no USDT created',
      sumClaimable + sumLifetimeClaimed <= creditedToParticipants,
      `owed+paid=${sumClaimable + sumLifetimeClaimed} credited=${creditedToParticipants}`);

    // I14 Nothing is stranded. I7 only bounds the view from above, so a
    //     truncating cast could leave real HCOW behind shares nobody holds and
    //     I7 would still pass. Attribution must also be tight from below:
    //     the gap is rounding only, at most one wei per holder.
    must(seed, op, 'I14 bonded HCOW is fully attributed',
      totalBonded - sumBondedOf <= BigInt(actors.length),
      `unattributed=${totalBonded - sumBondedOf} holders=${holders}`);

    // I17 Shares bonded during the open epoch are counted, and never exceed
    //     the total. If they did, the settlement divisor would underflow.
    const newShares = await ps.totalNewShares();
    must(seed, op, 'I17 new shares within total', newShares <= totalShares,
      `new=${newShares} total=${totalShares}`);

    // I16 A pending unbond can never redeem more than it reserved.
    let sumRedeemable = 0n;
    for (const a of actors) {
      sumRedeemable += await ps.pendingUnbondOf(await a.getAddress());
    }
    must(seed, op, 'I16 pending redeems no more than reserved',
      sumRedeemable <= totalPending, `redeem=${sumRedeemable} reserve=${totalPending}`);

    // I15 The pool decay index never rises, and never reaches zero.
    const idx = await ps.poolIndex();
    must(seed, op, 'I15 poolIndex monotonic and live',
      idx <= lastPoolIndex && idx > 0n, `${idx} vs ${lastPoolIndex}`);

    // I13 Reported pending equals the pool reserve. The reserve holds the
    //     amounts as requested; the charge is applied when the position leaves.
    must(seed, op, 'I13 pending reserve exact', sumPending === totalPending,
      `sum=${sumPending} total=${totalPending}`);

    lastPoolIndex = idx;
    lastAccUsdt = accUsdt;
    lastAccDeducted = accDed;
    lastDistributed = distributed;
    lastDeducted = deducted;
  }
}

// ---------------------------------------------------------------------- main
(async () => {
  const SEEDS = [1, 7, 42, 1337, 20260818, 99991, 5150, 8675309];
  const OPS = Number(process.env.INV_OPS || 220);

  console.log(`HCOWProfitShare invariant run: ${SEEDS.length} seeds x ${OPS} ops`);
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
  if (violations.length === 0) {
    console.log('all invariants held');
    process.exit(0);
  }
  const byName = {};
  for (const v of violations) (byName[v.name] ||= []).push(v);
  console.log(`\n${violations.length} violation(s):`);
  for (const [name, list] of Object.entries(byName)) {
    console.log(`\n  ${name}  x${list.length}`);
    console.log(`    first: seed=${list[0].seed} op=${list[0].op} ${list[0].detail}`);
  }
  process.exit(1);
})();
