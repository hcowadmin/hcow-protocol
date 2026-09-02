// Exercises the deployed contracts on a live network with real transactions.
//
//   DEPLOYER_KEY=0x... npx hardhat run scripts/smoke.cjs --network bscTestnet
//
// Reads deployments/<network>.json. Compiling is not proof; this is the proof.
// Every step below is a transaction that either lands on the explorer or fails
// loudly.
//
// ROLE SEPARATION. This script used to run one signer as owner, settler,
// funder, anchorer and participant. That passes against a deployment where one
// wallet holds everything, which is exactly the deployment mainnet forbids, so
// a green run said nothing about the deployment we intend to ship. Each
// privileged section now signs as the role that owns it, and takes that role's
// key from the environment:
//
//   OWNER_KEY  ANCHORER_KEY  SETTLER_KEY  FUNDER_KEY
//
// A missing key is not a failure and not a pass: the section is SKIPPED with
// the address it needed, and the run exits non-zero. A key whose address does
// not match the deployment record is a hard error, because the likeliest cause
// is a rehearsal pointed at the wrong deployment.
//
// It is destructive by design: it moves test USDT and writes epoch 0 into the
// anchor. Never point it at a live deployment.

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const { connect, at, ethers } = require("./_connect.cjs");
const { leafHash } = require("../lib/canonical");
const { buildTree, getProof, verifyProof } = require("../lib/merkle");

const E = (n) => ethers.parseUnits(String(n), 18);
const fmt = (v) => ethers.formatUnits(v, 18);

let pass = 0, fail = 0, skipped = 0;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ok    ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? "  " + detail : ""}`); }
}
/**
 * A section this run could not reach.
 *
 * Tracked, not swallowed. A green exit that verified almost nothing is worse
 * than a red one, so a skip still fails the run.
 */
function skip(section, why) {
  skipped++;
  console.log(`  SKIPPED  ${section}: ${why}`);
}

async function main() {
  const { provider, signer } = connect();
  const net = await provider.getNetwork();
  if (net.chainId === 56n) throw new Error("refusing to run the smoke test on BSC mainnet");

  const file = path.join(__dirname, "..", "deployments", `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}, run deploy.cjs first`);
  const d = JSON.parse(fs.readFileSync(file, "utf8"));
  const a = d.addresses;
  const roles = d.roles || {};

  const me = await signer.getAddress();
  console.log(`network ${hre.network.name}  participant ${me}\n`);

  /**
   * The signer that holds `role`, or null with the reason it is unavailable.
   *
   * Falling back to the deploy key silently is what made the old script pass
   * against a deployment it could not actually drive: every privileged call
   * was signed by a wallet that happened to hold every role. The fallback
   * survives only where the deployment record itself says the role IS the
   * deploy key, which is the un-rehearsed testnet shape and is reported as
   * such.
   */
  const cache = new Map();
  async function as(role) {
    if (cache.has(role)) return cache.get(role);
    const want = roles[role];
    let out;
    if (!want) {
      out = { signer: null, why: `deployment record has no ${role} address` };
    } else if (want.toLowerCase() === me.toLowerCase()) {
      out = { signer, shared: true };
    } else {
      const key = process.env[`${role.toUpperCase()}_KEY`];
      if (!key) {
        out = { signer: null, why: `${role.toUpperCase()}_KEY not set, ${role} is ${want}` };
      } else {
        const w = new ethers.NonceManager(new ethers.Wallet(key, provider));
        const got = await w.getAddress();
        if (got.toLowerCase() !== want.toLowerCase()) {
          throw new Error(
            `${role.toUpperCase()}_KEY is ${got} but the deployment records ` +
            `${role} as ${want}. Refusing to continue: this is either the wrong ` +
            `key or the wrong deployment.`);
        }
        const bal = await provider.getBalance(got);
        if (bal === 0n) {
          out = { signer: null, why: `${role} ${got} has no gas, run scripts/fundroles.cjs` };
        } else {
          out = { signer: w };
        }
      }
    }
    cache.set(role, out);
    return out;
  }

  const shape = Object.entries(roles)
    .filter(([, v]) => v && v.toLowerCase() === me.toLowerCase())
    .map(([k]) => k);
  if (shape.length) {
    console.log(`NOTE: the deploy key also holds ${shape.join(", ")}. ` +
                `This is the un-rehearsed testnet shape; mainnet forbids it.\n`);
  }

  const hcow = await at("MockHCOW", a.HCOW, signer);
  const usdt = await at("MockUSDT", a.USDT, signer);
  const ledger = await at("HCOWLedger", a.HCOWLedger, signer);
  const profit = await at("HCOWProfitShare", a.HCOWProfitShare, signer);
  const staking = await at("HCOWStaking", a.HCOWStaking, signer);

  // ---------------------------------------------------------------- ledger
  console.log("HCOWLedger");
  const records = [];
  for (let i = 0; i < 5; i++) {
    records.push({
      gameId: "tint", roundId: `smoke-${i}`, playerRef: `p${i}`,
      mode: "campaign", level: 3 + i, score: 1000 * (i + 1),
      durationMs: 40000 + i, outcome: "cleared", endedAt: 1760000000 + i,
    });
  }
  const leaves = records.map((r) => leafHash(r, "skill"));
  const { root, levels } = buildTree(leaves);
  const proof = getProof(levels, 2);
  ok("proof verifies locally before publishing", verifyProof(leaves[2], proof, root, leaves.length));

  const nextEpoch = await ledger.nextEpoch();
  const chainId = Number(net.chainId);
  if (chainId === 56) throw new Error("smoke.cjs must never run on BNB mainnet");
  const endsAt = (BigInt(nextEpoch) + 1n) * 3600n;
  const nowTs = BigInt((await provider.getBlock("latest")).timestamp);
  let tx, rc;
  const anchorer = await as("anchorer");
  if (nowTs < endsAt) {
    // An epoch may only be anchored after the period it covers has finished,
    // so this is expected rather than an error.
    skip("ledger anchor", `epoch ${nextEpoch} ends at ${endsAt}, now ${nowTs}`);
  } else if (!anchorer.signer) {
    skip("ledger anchor", anchorer.why);
  } else {
    // Signed by the anchorer, which is the whole point: on mainnet this wallet
    // holds gas and nothing else, and the ledger accepts it and no one else.
    const asAnchorer = await at("HCOWLedger", a.HCOWLedger, anchorer.signer);
    tx = await asAnchorer.anchorEpoch(nextEpoch, root, records.length);
    rc = await tx.wait();
    console.log(`  anchored epoch ${nextEpoch} as anchorer  tx ${rc.hash}  gas ${rc.gasUsed}`);

    const stored = await ledger.getEpoch(nextEpoch);
    ok("stored root matches", stored.root.toLowerCase() === root.toLowerCase());
    ok("record count stored", stored.recordCount === BigInt(records.length));
    ok("contract verifies a real proof", await ledger.verifyEpochRecord(nextEpoch, leaves[2], proof));
    const tampered = leafHash({ ...records[2], score: 999999 }, "skill");
    ok("contract rejects a tampered record", !(await ledger.verifyEpochRecord(nextEpoch, tampered, proof)));
    // The separation is only real if the other side of it is enforced. A
    // participant is the closest thing to "anybody" this script has.
    if (!anchorer.shared) {
      // staticCall, not a real send. A reverting send still consumes a nonce
      // from this signer's NonceManager, and every later transaction in the
      // run then arrives with a nonce the node will not accept. The refusal is
      // what is being asserted, and a static call proves it exactly.
      const refused = await ledger.anchorEpoch.staticCall(nextEpoch + 1n, root, 1)
        .then(() => false, () => true);
      ok("the ledger refuses an anchor from a non-anchorer", refused);
    }
  }

  // ----------------------------------------------------------- profit share
  console.log("\nHCOWProfitShare");
  const BOND = E(1000);
  tx = await hcow.approve(a.HCOWProfitShare, BOND); await tx.wait();
  tx = await profit.bond(BOND); rc = await tx.wait();
  console.log(`  bonded ${fmt(BOND)} HCOW  tx ${rc.hash}`);
  ok("bonded balance credited", (await profit.bondedOf(me)) === BOND);

  // A bond does not earn the epoch it arrives in, and epochs have a minimum
  // length, so a single run cannot demonstrate a full distribution to this
  // account. What it can demonstrate is the waterfall arithmetic and the
  // refusals, which is what this script is for.
  ok("the bond is not earning yet", (await profit.eligibleSharesOf(me)) === 0n);
  ok("but it is principal already", (await profit.bondedOf(me)) === BOND);

  const openAt = await profit.epochOpensAt();
  const settler = await as("settler");
  if (openAt !== 0n) {
    skip("settlement", `the next epoch opens at ${openAt}`);
  } else if (!settler.signer) {
    skip("settlement", settler.why);
  } else {
    // gross 1000, direct 100 -> net 900. opex 200 is under the 40% cap of 360.
    // profit 700, participants 350, game company 175, team 175.
    //
    // The bond above was made in the epoch this settles, so it is not eligible
    // yet: the participant leg is scaled to the eligible fraction of the pool,
    // which is zero, and the whole 350 goes back to the settler as
    // refundedUsdt. No deduction either: the contract refuses to consume
    // principal in an epoch that credited nobody.
    const gross = E(1000), direct = E(100), opex = E(200);
    const epoch = await profit.nextEpoch();
    ok("a deduction with nobody eligible is refused",
       (await profit.deductionFor(10_000)) === 0n);

    // The settler funds the distribution out of its OWN balance. On the shared
    // shape that is the deploy key and the check is vacuous; separated, an
    // empty settler is the first thing a mainnet run would discover.
    const asSettler = await at("HCOWProfitShare", a.HCOWProfitShare, settler.signer);
    const usdtAsSettler = await at("MockUSDT", a.USDT, settler.signer);
    const settlerAddr = await settler.signer.getAddress();
    const held = await usdt.balanceOf(settlerAddr);
    if (held < E(700)) {
      skip("settlement", `settler ${settlerAddr} holds ${fmt(held)} USDT, needs 700. ` +
                         `Run scripts/fundroles.cjs`);
    } else {
      tx = await usdtAsSettler.approve(a.HCOWProfitShare, E(700)); await tx.wait();
      tx = await asSettler.settleEpoch(epoch, gross, direct, opex, 0); rc = await tx.wait();
      console.log(`  settled epoch ${epoch} as settler  tx ${rc.hash}  gas ${rc.gasUsed}`);

      const s = await profit.getSettlement(epoch);
      ok("distributable profit is 700", s.distributableProfitUsdt === E(700), fmt(s.distributableProfitUsdt));
      ok("the bond is earning from the next epoch",
         (await profit.eligibleSharesOf(me)) > 0n);
      ok("the game company leg was paid 175",
         (await usdt.balanceOf(roles.gameCompany)) >= E(175), fmt(await usdt.balanceOf(roles.gameCompany)));
      ok("the team leg was paid 175",
         (await usdt.balanceOf(roles.team)) >= E(175), fmt(await usdt.balanceOf(roles.team)));
      if (!settler.shared) {
        const refused = await profit.settleEpoch
          .staticCall(epoch + 1n, gross, direct, opex, 0)
          .then(() => false, () => true);
        ok("settlement from a non-settler is refused", refused);
      }
    }
  }

  // --------------------------------------------------------------- staking
  console.log("\nHCOWStaking");
  const REP = ethers.encodeBytes32String("smoke-rep");
  // representativeOf reverts on an unknown id rather than returning a blank
  // struct, so absence is detected by the revert.
  const already = await staking.representativeOf(REP).then(() => true, () => false);
  const owner = await as("owner");
  if (!already && !owner.signer) {
    skip("representative registration", owner.why);
  } else if (!already) {
    const asOwner = await at("HCOWStaking", a.HCOWStaking, owner.signer);
    tx = await asOwner.registerRepresentative(REP, "Smoke Validator", me, 500, false);
    rc = await tx.wait();
    console.log(`  registered representative as owner  tx ${rc.hash}`);
    if (!owner.shared) {
      const refused = await staking.registerRepresentative
        .staticCall(ethers.encodeBytes32String("smoke-rep-2"), "Nope", me, 500, false)
        .then(() => false, () => true);
      ok("representative registration from a non-owner is refused", refused);
    }
  }

  if (!(await staking.representativeOf(REP).then(() => true, () => false))) {
    skip("staking", "no representative to delegate to");
  } else {
    const STAKE = E(5000);
    tx = await hcow.approve(a.HCOWStaking, STAKE); await tx.wait();
    tx = await staking.stake(STAKE, REP); rc = await tx.wait();
    console.log(`  staked ${fmt(STAKE)} HCOW  tx ${rc.hash}`);

    // Rewards stream over a period. A smoke run cannot wait one out, so fund a
    // one day period and check that it starts flowing rather than that it has
    // finished.
    const REWARD = E(100);
    const DURATION = 24 * 60 * 60;
    const funder = await as("funder");
    if (!funder.signer) {
      skip("reward funding", funder.why);
    } else {
      const asFunder = await at("HCOWStaking", a.HCOWStaking, funder.signer);
      const hcowAsFunder = await at("MockHCOW", a.HCOW, funder.signer);
      const funderAddr = await funder.signer.getAddress();
      const held = await hcow.balanceOf(funderAddr);
      if (held < REWARD) {
        skip("reward funding", `funder ${funderAddr} holds ${fmt(held)} HCOW, needs 100. ` +
                               `Run scripts/fundroles.cjs`);
      } else {
        tx = await hcowAsFunder.approve(a.HCOWStaking, REWARD); await tx.wait();
        tx = await asFunder.fundRewards(REWARD, DURATION); rc = await tx.wait();
        console.log(`  funded ${fmt(REWARD)} HCOW over ${DURATION}s as funder  tx ${rc.hash}`);

        const rate = await staking.rewardRate();
        ok("reward rate is the amount over the duration", rate === REWARD / BigInt(DURATION), String(rate));
        ok("the period is open", (await staking.periodFinish()) > BigInt(Math.floor(Date.now() / 1000)));

        // A few seconds of a day long stream is a very small number, so assert
        // the shape rather than an exact figure.
        await new Promise((r) => setTimeout(r, 6000));
        const pending = await staking.pendingRewardOf(me);
        ok("the single delegator is accruing", pending > 0n, fmt(pending));
        ok("and is accruing less than the whole period", pending < REWARD, fmt(pending));
        const commission = await staking.commissionOf(REP);
        ok("commission is accruing to the representative", commission > 0n, fmt(commission));
        ok("commission is 5% of what has been released",
           commission * 19n >= pending - 2n && commission * 19n <= pending + 2n,
           `${fmt(commission)} vs ${fmt(pending)}`);
      }
    }
  }
}

function report() {
  console.log(`\n${pass} passed, ${fail} failed, ${skipped} section(s) skipped`);
  // A skipped section is not a pass. The exit code says so, because the whole
  // point of this script is that a green exit means the deployed contracts
  // were exercised, and a run that could not reach half of them did not do
  // that.
  process.exitCode = (fail || skipped) ? 1 : 0;
}

main()
  .catch((e) => { console.error(e.message || e); fail++; })
  .finally(report);
