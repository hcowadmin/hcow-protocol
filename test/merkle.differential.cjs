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
 * Odd nodes used to be paired with themselves rather than promoted, which is
 * the CVE-2012-2459 shape: a tree over [a,b,c] and one over [a,b,c,c] had the
 * same root, and the required proof length was identical for both. Levels are
 * now padded to a power of two with EMPTY_LEAF, a filler that cannot be a
 * record, so the two are different trees. The record count is separately bound
 * into the anchored value. This file asserts both: that the collision no longer
 * exists, and that the count cannot be restated behind an unchanged root.
 */
const hre = require('hardhat');
const { ethers } = require('ethers');
const { buildTree, getProof, verifyProof, commit, hashPair, EMPTY_LEAF } = require('../lib/merkle');

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

  // ---- 1. depth agreement ----
  //
  // The loop used to run to 20,000 while building a tree only up to 400, so
  // 19,600 of the iterations did nothing and the section header claimed a
  // range the body did not cover. Two loops now, each honest about what it
  // does: the tree is built and its proof measured up to 400, and above that
  // the formula is checked against ceil(log2(n)) computed a different way,
  // which is the part that can run to 200,000 cheaply.
  {
    let bad = 0;
    for (let n = 1; n <= 400; n++) {
      const t = buildTree(Array.from({ length: n }, (_, i) => leafOf(i, 'd')));
      if (getProof(t.levels, 0).length !== depthOf(n)) bad++;
    }
    ok(bad === 0, 'a built tree proof is exactly depthOf(n) long, for every size up to 400', `${bad} mismatches`);

    let formulaBad = 0;
    for (let n = 1; n <= 200000; n++) {
      // ceil(log2(n)) by counting doublings, independent of the halving loop
      let p = 1, d = 0;
      while (p < n) { p *= 2; d += 1; }
      if (depthOf(n) !== d) formulaBad++;
    }
    ok(formulaBad === 0, 'depthOf is ceil(log2(n)) for every size up to 200,000', `${formulaBad} mismatches`);
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
      if (!verifyProof(leaves[i], proof, tree.root, n)) localBad++;
      if (!(await c.verifyEpochRecord(epoch, leaves[i], proof))) localBad++;
    }
    ok(localBad === 0, `n=${n}: every sampled leaf verifies in JS and on chain`, `${localBad} failures`);

    // The root itself, presented as a leaf with an empty proof. Skipped at
    // n == 1, where the root IS the leaf by definition and accepting it is
    // correct rather than a forgery.
    //
    // Both sides, always. The chain was checked here and the library was not,
    // and the library accepted all three forgeries below for as long as that
    // was true. A differential test that only drives one of the two
    // implementations is not a differential test.
    if (n > 1) {
      ok(!(await c.verifyEpochRecord(epoch, tree.root, [])), `n=${n}: the root is not accepted as a leaf`);
      ok(!verifyProof(tree.merkleRoot, [], tree.root, n),
         `n=${n}: the library does not accept the Merkle root as a leaf either`);
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

      let jsAccepted = 0;
      for (let lvl = 1; lvl < tree.levels.length - 1; lvl++) {
        const node = tree.levels[lvl][0];
        for (const p of [[], getProof(tree.levels, 0).slice(lvl), getProof(tree.levels, 0)]) {
          if (verifyProof(node, p, tree.root, n)) jsAccepted++;
        }
      }
      ok(jsAccepted === 0, `n=${n}: the library refuses every internal node too`, `${jsAccepted} accepted`);
    }

    // a proof of the wrong length, both directions
    if (n > 2) {
      const p = getProof(tree.levels, 0);
      ok(!(await c.verifyEpochRecord(epoch, leaves[0], p.slice(0, -1))), `n=${n}: a short proof is refused`);
      ok(!(await c.verifyEpochRecord(epoch, leaves[0], [...p, p[0]])), `n=${n}: an over-long proof is refused`);
      ok(!(await c.verifyEpochRecord(epoch, leaves[0], [...p].reverse())), `n=${n}: a reversed proof is refused`);
      ok(!verifyProof(leaves[0], p.slice(0, -1), tree.root, n),
         `n=${n}: the library refuses a short proof too`);
      ok(!verifyProof(leaves[0], [...p, p[0]], tree.root, n),
         `n=${n}: the library refuses an over-long proof too`);
    }

    // The padding filler is genuinely in the tree with a genuine proof, which
    // is exactly why it has to be refused by name. Only reachable when the
    // count is not already a power of two.
    if (n > 1 && (n & (n - 1)) !== 0) {
      const padIdx = tree.levels[0].length - 1;
      const padProof = getProof(tree.levels, padIdx);
      ok(!(await c.verifyEpochRecord(epoch, EMPTY_LEAF, padProof)),
         `n=${n}: the padding filler is not a record on chain`);
      ok(!verifyProof(EMPTY_LEAF, padProof, tree.root, n),
         `n=${n}: the padding filler is not a record in the library either`);
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
    // The builder refusing duplicates is a policy of one implementation, not a
    // property of the format, so the format has to separate them too. It does:
    // the anchored value is the Merkle root with the record count folded in,
    // and depth(3) == depth(4), so the proof length cannot tell them apart.
    ok(depthOf(3) === depthOf(4),
       'note: depth(3) == depth(4), so the proof length cannot distinguish them');
    const merkle3 = t3.merkleRoot;

    // The uniqueness half, which the count binding alone does not close. Levels
    // used to pair an odd node with itself, so the tree over three leaves and
    // the tree over those three plus a duplicate of the third produced the
    // identical root and required the identical proof length. Padding to a
    // power of two with a filler that is not a record separates them.
    const selfPaired = hashPair(hashPair(three[0], three[1]), hashPair(three[2], three[2]));
    ok(merkle3 !== selfPaired,
       'a tree of three does not collide with the same three plus a duplicate',
       `both ${merkle3}`);
    ok(merkle3 === hashPair(hashPair(three[0], three[1]), hashPair(three[2], EMPTY_LEAF)),
       'and the third leaf is paired with the published filler, not with itself');
    ok(commit(merkle3, 3) !== commit(merkle3, 4),
       'the same Merkle root under two record counts is two different anchored values');
    ok(commit(merkle3, 3) === t3.root, 'the anchored value is the root bound to its own count');

    // What the fold does and does not do, stated precisely, because the
    // difference is the whole substance of the finding.
    //
    // It does NOT let the contract detect an inflated count. The contract is
    // told both the value and the count by the same caller and has no
    // independent view of the record set; an anchorer that wants to claim four
    // records for a three record period simply anchors commit(root, 4) and
    // every receipt from that tree still verifies. Nothing on chain can close
    // that, and the response to the audit says so.
    //
    // What it does is make the claim checkable off chain. An observer who
    // rebuilds the tree from the published records computes commit(root, 3);
    // the chain holds commit(root, 4); the two differ and the inflation is
    // visible. Under the previous rule the observer computed the bare root,
    // the chain held the bare root, they agreed, and the count beside them was
    // an assertion nothing could contradict.
    await finish(epoch);
    await (await c.anchorEpoch(epoch, commit(merkle3, 4), 4)).wait();
    ok(await c.verifyEpochRecord(epoch, three[0], getProof(t3.levels, 0)),
       'note: an inflated count is still internally consistent on chain');
    const onChain = (await c.getEpoch(epoch)).root;
    ok(onChain.toLowerCase() !== commit(merkle3, 3).toLowerCase(),
       'but it no longer matches what the published record set rebuilds to');
    epoch++;

    // and the honest anchor is the one the published set does reproduce
    await finish(epoch);
    await (await c.anchorEpoch(epoch, t3.root, 3)).wait();
    ok((await c.getEpoch(epoch)).root.toLowerCase() === commit(merkle3, 3).toLowerCase(),
       'an honest anchor is exactly what the published record set rebuilds to');
    ok(await c.verifyEpochRecord(epoch, three[0], getProof(t3.levels, 0)),
       'and every receipt under it verifies');
    epoch++;

    // an anchor in the old format, the bare Merkle root, is simply not valid
    await finish(epoch);
    await (await c.anchorEpoch(epoch, merkle3, 3)).wait();
    ok(!(await c.verifyEpochRecord(epoch, three[0], getProof(t3.levels, 0))),
       'a bare Merkle root anchored without the count binding verifies nothing');
    epoch++;
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
