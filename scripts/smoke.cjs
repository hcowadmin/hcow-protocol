// Exercises the deployed contracts on a live network with real transactions.
//
//   npx hardhat run scripts/smoke.cjs --network bscTestnet
//
// Reads deployments/<network>.json. Compiling is not proof; this is the proof.
// Every step below is a transaction that either lands on the explorer or fails
// loudly. It runs one signer as owner, settler, funder and participant, which
// is only acceptable on testnet.
//
// It is destructive by design: it burns test HCOW, moves test USDT and writes
// epoch 0 into the anchor. Never point it at a live deployment.

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");
const { connect, at, ethers } = require("./_connect.cjs");
const { leafHash } = require("../lib/canonical");
const { buildTree, getProof, verifyProof } = require("../lib/merkle");

const E = (n) => ethers.parseUnits(String(n), 18);
const fmt = (v) => ethers.formatUnits(v, 18);

let pass = 0, fail = 0;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ok    ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? "  " + detail : ""}`); }
}

async function main() {
  const { provider, signer } = connect();
  const net = await provider.getNetwork();
  if (net.chainId === 56n) throw new Error("refusing to run the smoke test on BSC mainnet");

  const file = path.join(__dirname, "..", "deployments", `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}, run deploy.cjs first`);
  const d = JSON.parse(fs.readFileSync(file, "utf8"));
  const a = d.addresses;

  const me = await signer.getAddress();
  console.log(`network ${hre.network.name}  signer ${me}\n`);

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
  ok("proof verifies locally before publishing", verifyProof(leaves[2], proof, root));

  const nextEpoch = await ledger.nextEpoch();
  // Refuse to write junk into a live ledger: the epoch numbering is permanent
  // and a smoke run would offset every real hour after it.
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  if (chainId === 56) throw new Error("smoke.cjs must never run on BNB mainnet");
  const endsAt = (BigInt(nextEpoch) + 1n) * 3600n;
  const nowTs = BigInt((await ethers.provider.getBlock("latest")).timestamp);
  if (nowTs < endsAt) {
    console.log(`  skipping ledger anchor: epoch ${nextEpoch} ends at ${endsAt}, now ${nowTs}`);
    return;
  }
  let tx = await ledger.anchorEpoch(nextEpoch, root, records.length);
  let rc = await tx.wait();
  console.log(`  anchored epoch ${nextEpoch}  tx ${rc.hash}  gas ${rc.gasUsed}`);

  const stored = await ledger.getEpoch(nextEpoch);
  ok("stored root matches", stored.root.toLowerCase() === root.toLowerCase());
  ok("record count stored", stored.recordCount === BigInt(records.length));
  ok("contract verifies a real proof", await ledger.verifyEpochRecord(nextEpoch, leaves[2], proof));
  const tampered = leafHash({ ...records[2], score: 999999 }, "skill");
  ok("contract rejects a tampered record", !(await ledger.verifyEpochRecord(nextEpoch, tampered, proof)));

  // ----------------------------------------------------------- profit share
  console.log("\nHCOWProfitShare");
  const BOND = E(1000);
  tx = await hcow.approve(a.HCOWProfitShare, BOND); await tx.wait();
  tx = await profit.bond(BOND); rc = await tx.wait();
  console.log(`  bonded ${fmt(BOND)} HCOW  tx ${rc.hash}`);
  ok("bonded balance credited", (await profit.bondedOf(me)) === BOND);

  // gross 1000, direct 100 -> net 900. opex 200 is under the 40% cap of 360.
  // profit 700, participants 350, game company 175, team 175.
  // deduction is stated as a rate now: 10,000 ppm is 1% of the 1000 HCOW pool.
  const gross = E(1000), direct = E(100), opex = E(200), deductPpm = 10_000;
  const epoch = await profit.nextEpoch();
  const deduct = await profit.deductionFor(deductPpm);
  tx = await usdt.approve(a.HCOWProfitShare, E(700)); await tx.wait();
  tx = await profit.settleEpoch(epoch, gross, direct, opex, deductPpm); rc = await tx.wait();
  console.log(`  settled epoch ${epoch}  tx ${rc.hash}  gas ${rc.gasUsed}`);

  const s = await profit.getSettlement(epoch);
  ok("distributable profit is 700", s.distributableProfitUsdt === E(700), fmt(s.distributableProfitUsdt));
  ok("participant share is 350", s.participantsUsdt === E(350), fmt(s.participantsUsdt));
  ok("deduction recorded", s.hcowDeducted === deduct);
  ok("pool shrank by the deduction", (await profit.bondedOf(me)) === BOND - deduct);
  ok("deducted HCOW was burned", (await hcow.totalSupply()) === E(200_000_000) - deduct);

  const claimable = await profit.claimableOf(me);
  ok("claimable is the participant share", claimable === E(350), fmt(claimable));
  const before = await usdt.balanceOf(me);
  tx = await profit.claimUsdt(); rc = await tx.wait();
  ok("USDT actually arrived", (await usdt.balanceOf(me)) - before === E(350));
  console.log(`  claimed 350 USDT  tx ${rc.hash}`);

  // --------------------------------------------------------------- staking
  console.log("\nHCOWStaking");
  const REP = ethers.encodeBytes32String("smoke-rep");
  // representativeOf reverts on an unknown id rather than returning a blank
  // struct, so absence is detected by the revert.
  const already = await staking.representativeOf(REP).then(() => true, () => false);
  if (!already) {
    tx = await staking.registerRepresentative(REP, "Smoke Validator", me, 500, false);
    rc = await tx.wait();
    console.log(`  registered representative  tx ${rc.hash}`);
  }

  const STAKE = E(5000);
  tx = await hcow.approve(a.HCOWStaking, STAKE); await tx.wait();
  tx = await staking.stake(STAKE, REP); rc = await tx.wait();
  console.log(`  staked ${fmt(STAKE)} HCOW  tx ${rc.hash}`);

  // Rewards stream over a period. A smoke run cannot wait one out, so fund a
  // one day period and check that it starts flowing rather than that it has
  // finished.
  const REWARD = E(100);
  const DURATION = 24 * 60 * 60;
  tx = await hcow.approve(a.HCOWStaking, REWARD); await tx.wait();
  tx = await staking.fundRewards(REWARD, DURATION); rc = await tx.wait();
  console.log(`  funded ${fmt(REWARD)} HCOW over ${DURATION}s  tx ${rc.hash}`);

  const rate = await staking.rewardRate();
  ok("reward rate is the amount over the duration", rate === REWARD / BigInt(DURATION), String(rate));
  ok("the period is open", (await staking.periodFinish()) > BigInt(Math.floor(Date.now() / 1000)));

  // A few seconds of a day long stream is a very small number, so assert the
  // shape rather than an exact figure.
  await new Promise((r) => setTimeout(r, 6000));
  const pending = await staking.pendingRewardOf(me);
  ok("the single delegator is accruing", pending > 0n, fmt(pending));
  ok("and is accruing less than the whole period", pending < REWARD, fmt(pending));
  const commission = await staking.commissionOf(REP);
  ok("commission is accruing to the representative", commission > 0n, fmt(commission));
  ok("commission is 5% of what has been released",
     commission * 19n >= pending - 2n && commission * 19n <= pending + 2n,
     `${fmt(commission)} vs ${fmt(pending)}`);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
