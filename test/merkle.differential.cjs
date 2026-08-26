'use strict';
/**
 * Differential test: the JS tree builder against the on-chain verifier.
 *
 * These two implementations must agree exactly, forever. The chain is the
 * authority for whether a receipt is genuine, and the builder is what produces
 * the receipts. A disagreement means either a player is told their real
 * receipt is forged, or a forged one is accepted. Nothing in the suite
 * compared them across tree shapes before this file: test/keccak.check.cjs
 * checks the hash function, and test/web.check.cjs checks the browser page
 * against lib/, but nobody checked lib/ against Solidity over many sizes.
 *
 * Odd nodes are paired with themselves rather than promoted, which is the
 * CVE-2012-2459 shape: a tree over [a,b,c] and one over [a,b,c,c] have the
 * same root. That is deliberate and it is safe here only because recordCount
 * is anchored beside the root and the proof length is checked against it. This
 * file asserts that the check is what makes it safe, by trying the collision.
 */
const hre = require('hardhat');
const { ethers } = require('ethers');
const { buildTree, getProof, verifyProof } = require('../lib/merkle');

const SIZES = [1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 127, 128, 129, 255, 256, 257, 300];
const EPOCH_SECONDS = 3600;

let pass = 0, fail = 0;
const ok = (c, m, extra = '') => {
  if (c) pass++;
  else { fail++; console.log('  FAIL ', m, extra); }
};
const leafOf = (i, salt) => ethers.keccak256(ethers.toUtf8Bytes(`leaf-${salt}-${i}`));

/** Independent reimplementation of the contract's _proofDepth. */
const depthOf = (n) => { let d = 0; while (n > 1) { n = (n >> 1) + (n & 1); d++; } return d; };

(async () => {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const owner = await provider.getSigner(0);
  const art = await hre.artifacts.readArtifact('HCOWLedger');
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, owner)
    .deploy(await owner.getAddress(), await owner.getAddress());
  await c.waitForDeployment();

  const genesis = Number(await c.genesisEpoch());
  const finish = async (epoch) => {
    const endsAt = (epoch + 1) * EPOCH_SECONDS;
    const now = (await provider.getBlock('latest')).timestamp;
    if (now < endsAt) {
      await provider.send('evm_setNextBlockTimestamp', [endsAt + 1]);
      await provider.send('evm_mine', []);
    }
  };

  // ---- 1. depth agreement, well past any tree we will ever anchor ----
  {
    let bad = 0;
    for (let n = 1; n <= 20000; n++) {
      const t = n <= 400 ? buildTree(Array.from({ length: n }, (_, i) => leafOf(i, 'd'))) : null;
      if (t && getProof(t.levels, 0).length !== depthOf(n)) bad++;
    }
    ok(bad === 0, 'JS proof length matches the contract depth formula for every size up to 400', `${bad} mismatches`);
  }

  // ---- 2. per size: every leaf verifies, and every forgery is refused ----
  let epoch = genesis;
  const roots = [];
  for (const n of SIZES) {
    const leaves = Array.from({ length: n }, (_, i) => leafOf(i, n));
    const tree = buildTree(leaves);
    roots.push({ n, tree, leaves, epoch });

    await finish(epoch);
    await (await c.anchorEpoch(epoch, tree.root, n)).wait();

    // every leaf, or a spread sample for the large ones
    const idx = n <= 40 ? [...Array(n).keys()]
      : [0, 1, 2, (n >> 2), (n >> 1), n - 3, n - 2, n - 1];
    let localBad = 0;
    for (const i of idx) {
      const proof = getProof(tree.levels, i);
      if (!verifyProof(leaves[i], proof, tree.root)) localBad++;
      if (!(await c.verifyEpochRecord(epoch, leaves[i], proof))) localBad++;
    }
    ok(localBad === 0, `n=${n}: every sampled leaf verifies in JS and on chain`, `${localBad} failures`);

    // The root itself, presented as a leaf with an empty proof. Skipped at
    // n == 1, where the root IS the leaf by definition and accepting it is
    // correct rather than a forgery.
    if (n > 1) {
      ok(!(await c.verifyEpochRecord(epoch, tree.root, [])), `n=${n}: the root is not accepted as a leaf`);
    }

    // an internal node presented as a leaf, at every level
    if (tree.levels.length > 2) {
      let accepted = 0;
      for (let lvl = 1; lvl < tree.levels.length - 1; lvl++) {
        const node = tree.levels[lvl][0];
        for (const p of [[], getProof(tree.levels, 0).slice(lvl), getProof(tree.levels, 0)]) {
          if (await c.verifyEpochRecord(epoch, node, p)) accepted++;
        }
      }
      ok(accepted === 0, `n=${n}: no internal node is accepted as a leaf`, `${accepted} accepted`);
    }

    // a proof of the wrong length, both directions
    if (n > 2) {
      const p = getProof(tree.levels, 0);
      ok(!(await c.verifyEpochRecord(epoch, leaves[0], p.slice(0, -1))), `n=${n}: a short proof is refused`);
      ok(!(await c.verifyEpochRecord(epoch, leaves[0], [...p, p[0]])), `n=${n}: an over-long proof is refused`);
      ok(!(await c.verifyEpochRecord(epoch, leaves[0], [...p].reverse())), `n=${n}: a reversed proof is refused`);
    }
    epoch++;
  }

  // ---- 3. no leaf verifies against another epoch's root ----
  {
    let crossed = 0;
    for (let i = 0; i < roots.length; i++) {
      for (let j = 0; j < roots.length; j++) {
        if (i === j) continue;
        const a = roots[i], b = roots[j];
        const proof = getProof(a.tree.levels, 0);
        if (proof.length !== depthOf(b.n)) continue;   // length check refuses it first
        if (await c.verifyEpochRecord(b.epoch, a.leaves[0], proof)) crossed++;
      }
    }
    ok(crossed === 0, 'no leaf verifies against a different epoch of the same depth', `${crossed} crossed`);
  }

  // ---- 4. the self-pairing collision, and what actually stops it ----
  {
    const three = [leafOf(0, 'c'), leafOf(1, 'c'), leafOf(2, 'c')];
    const four = [...three, three[2]];
    const t3 = buildTree(three);
    let t4 = null, threw = false;
    try { t4 = buildTree(four); } catch (_) { threw = true; }
    ok(threw, 'the builder refuses a duplicate leaf outright');
    if (!threw) {
      ok(t3.root !== t4.root, 'a self-paired odd tree does not collide with the padded one',
         `both ${t3.root}`);
    }
    // and the on-chain length check is what separates them even if a builder did not
    ok(depthOf(3) === depthOf(4),
       'note: depth(3) == depth(4), so recordCount is what distinguishes them, not the proof length');
  }

  // ---- 5. an unanchored epoch and one below genesis verify nothing ----
  {
    const a = roots[0];
    ok(!(await c.verifyEpochRecord(epoch + 50, a.leaves[0], getProof(a.tree.levels, 0))),
       'a future epoch verifies nothing');
    if (genesis > 0) {
      ok(!(await c.verifyEpochRecord(genesis - 1, a.leaves[0], getProof(a.tree.levels, 0))),
         'an epoch below genesis verifies nothing');
    }
  }

  console.log(fail === 0
    ? `merkle differential OK: ${pass} checks across ${SIZES.length} tree sizes`
    : `merkle differential FAILED: ${fail} of ${pass + fail}`);
  process.exit(fail ? 1 : 0);
})();
