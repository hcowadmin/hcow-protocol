'use strict';
// Anchors one epoch as the anchorer, and checks what the anchor is for.
//
//   ANCHORER_KEY=0x... npx hardhat run scripts/anchor.cjs --network bscTestnet
//
// Split out of smoke.cjs deliberately. An epoch may only be anchored after the
// period it covers has finished, so a smoke run started inside the current
// hour can never reach the ledger section, and re-running the whole smoke to
// pick it up re-bonds, re-stakes and re-settles against contracts that already
// hold the state from the first run. Those second-run failures are artifacts
// of the re-run rather than defects, which is the most expensive kind of red
// to read.
//
// This script touches nothing but the ledger and is safe to run repeatedly: it
// anchors whatever epoch is next and, if that epoch is still in progress, says
// how long is left and stops without writing anything.
//
// It is also the operation the hourly indexer performs in production, so a run
// here is a rehearsal of that and not only of the deployment.

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect, at, ethers } = require('./_connect.cjs');
const { leafHash } = require('../lib/canonical');
const { buildTree, getProof, verifyProof } = require('../lib/merkle');

let pass = 0, fail = 0;
const ok = (name, cond, detail) => {
  if (cond) { pass++; console.log(`  ok    ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`); }
};

async function main() {
  const { provider, signer } = connect();
  const net = await provider.getNetwork();
  if (net.chainId === 56n) throw new Error('refusing to write test records into the mainnet ledger');

  const file = path.join(__dirname, '..', 'deployments', `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}, run deploy.cjs first`);
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  const roles = d.roles || {};

  const me = await signer.getAddress();
  console.log(`network ${hre.network.name}  ledger ${d.addresses.HCOWLedger}\n`);

  // The anchorer, resolved the same way smoke.cjs resolves it: from the
  // deployment record, and refusing a key that does not match it.
  let anchorSigner;
  if (roles.anchorer && roles.anchorer.toLowerCase() === me.toLowerCase()) {
    anchorSigner = signer;
    console.log('NOTE: the deploy key is also the anchorer. Mainnet forbids this.\n');
  } else {
    const key = process.env.ANCHORER_KEY;
    if (!key) throw new Error(`ANCHORER_KEY is not set. The anchorer is ${roles.anchorer}.`);
    const w = new ethers.NonceManager(new ethers.Wallet(key, provider));
    const got = await w.getAddress();
    if (got.toLowerCase() !== (roles.anchorer || '').toLowerCase()) {
      throw new Error(
        `ANCHORER_KEY is ${got} but the deployment records the anchorer as ` +
        `${roles.anchorer}. Refusing to continue.`);
    }
    if ((await provider.getBalance(got)) === 0n) {
      throw new Error(`anchorer ${got} has no gas. Run scripts/fundroles.cjs`);
    }
    anchorSigner = w;
  }

  const ledger = await at('HCOWLedger', d.addresses.HCOWLedger, signer);
  const epoch = await ledger.nextEpoch();
  const endsAt = (BigInt(epoch) + 1n) * 3600n;
  const now = BigInt((await provider.getBlock('latest')).timestamp);

  // Not an error and not a failure. The period an epoch covers has to be over
  // before it can be summarised, so this is the contract working.
  if (now < endsAt) {
    const wait = Number(endsAt - now);
    console.log(`epoch ${epoch} is still in progress. It ends in ` +
                `${Math.floor(wait / 60)}m ${wait % 60}s. Nothing written.`);
    console.log('Re-run this script after that and it will anchor.');
    process.exitCode = 2;
    return;
  }

  const records = [];
  for (let i = 0; i < 5; i++) {
    records.push({
      gameId: 'tint', roundId: `anchor-${epoch}-${i}`, playerRef: `p${i}`,
      mode: 'campaign', level: 3 + i, score: 1000 * (i + 1),
      durationMs: 40000 + i, outcome: 'cleared', endedAt: Number(endsAt) - 60 + i,
    });
  }
  const leaves = records.map((r) => leafHash(r, 'skill'));
  const { root, levels } = buildTree(leaves);
  const proof = getProof(levels, 2);
  ok('proof verifies locally before publishing', verifyProof(leaves[2], proof, root, leaves.length));

  const asAnchorer = await at('HCOWLedger', d.addresses.HCOWLedger, anchorSigner);
  const tx = await asAnchorer.anchorEpoch(epoch, root, records.length);
  const rc = await tx.wait();
  console.log(`  anchored epoch ${epoch} as anchorer  tx ${rc.hash}  gas ${rc.gasUsed}`);

  const stored = await ledger.getEpoch(epoch);
  ok('stored root matches', stored.root.toLowerCase() === root.toLowerCase());
  ok('record count stored', stored.recordCount === BigInt(records.length));
  ok('contract verifies a real proof', await ledger.verifyEpochRecord(epoch, leaves[2], proof));

  // The point of the anchor. One field changed in one record and the same
  // proof no longer verifies against the published root.
  const tampered = leafHash({ ...records[2], score: 999999 }, 'skill');
  ok('contract rejects a tampered record', !(await ledger.verifyEpochRecord(epoch, tampered, proof)));

  // staticCall rather than a send: the refusal is what is being asserted, and
  // a reverting send would consume a nonce from this signer for nothing.
  if (anchorSigner !== signer) {
    const refused = await ledger.anchorEpoch.staticCall(BigInt(epoch) + 1n, root, 1)
      .then(() => false, () => true);
    ok('the ledger refuses an anchor from a non-anchorer', refused);
  }

  // Anchoring is once per epoch and permanent. Re-anchoring the same epoch has
  // to be impossible or the whole record layer means nothing.
  const again = await asAnchorer.anchorEpoch.staticCall(epoch, root, records.length)
    .then(() => false, () => true);
  ok('an already anchored epoch cannot be rewritten', again);
}

function report() {
  if (process.exitCode === 2) return;
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
}

main()
  .catch((e) => { console.error(e.message || e); fail++; })
  .finally(report);
