'use strict';
/**
 * Merkle tree with sorted pair hashing, matching HCOWLedger._verify.
 *
 * Sorted pairs mean a proof is just a list of sibling hashes with no
 * direction bits, which keeps proofs small and verification trivial in
 * any language. Levels are padded to a power of two with EMPTY_LEAF, so every
 * leaf sits at the same depth and a proof's length is a function of the record
 * count alone. Promoting an odd node instead would make two different leaf sets
 * produce one root and leave the contract unable to tell a short proof from a
 * forged one; pairing it with itself, which is what this did until the count
 * binding was added, did the same thing one level down.
 */

const { keccak256, concat, toBeHex } = require('ethers');

/**
 * Prefix on every internal node, matching HCOWLedger.NODE_PREFIX.
 *
 * A leaf preimage is a domain tag followed by text. A node preimage is this
 * byte followed by two 32 byte hashes. Without the prefix the two preimage
 * spaces overlap in principle and the separation rests on an argument about
 * how hard a steered collision would be. With it the separation is structural.
 */
const NODE_PREFIX = '0x01';

/**
 * Prefix on the final fold that binds the record count, matching
 * HCOWLedger.COUNT_PREFIX.
 *
 * Storing the bare Merkle root left the record count as a free-standing claim
 * beside it. The value that gets anchored is therefore not the bare root but
 *
 *     keccak256(0x02 ++ merkleRoot ++ uint64(recordCount))
 *
 * so a receipt issued for one count cannot be presented under another, and a
 * published record total cannot be inflated behind an unchanged root.
 */
const COUNT_PREFIX = '0x02';

/** The value HCOWLedger stores for a period that genuinely had no rounds. */
const EMPTY_PERIOD = keccak256(Buffer.from('HCOWv1|empty-period'));

/**
 * Filler leaf, matching HCOWLedger.EMPTY_LEAF.
 *
 * Levels used to pair an odd node with itself, which made a tree of n leaves
 * and a tree of n + 1 whose last leaf repeats the n-th produce the identical
 * root. Binding the count into the anchored value fixed the count and left
 * uniqueness open: a duplicated final record was still indistinguishable from
 * a distinct one, and the required proof length was identical for both.
 * Padding to a power of two with a filler that is not a record closes it. Proof
 * length is unchanged at ceil(log2(n)), so nothing else moves.
 *
 * It cannot collide with a record leaf: a canonical record preimage carries a
 * domain tag, eight tabs and a trailing newline, and this one carries none of
 * that.
 */
const EMPTY_LEAF = keccak256(Buffer.from('HCOWv1|empty-leaf'));

/**
 * Bind a Merkle root to the number of leaves under it. This is the value
 * passed to anchorEpoch and anchorHistorical, and the value a proof is checked
 * against.
 *
 * @param {string} merkleRoot 0x prefixed 32 byte hash
 * @param {number|bigint} recordCount number of leaves, as a uint64
 */
function commit(merkleRoot, recordCount) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(merkleRoot)) throw new Error(`bad root: ${merkleRoot}`);
  const n = BigInt(recordCount);
  if (n < 0n || n > 0xffffffffffffffffn) throw new Error(`bad record count: ${recordCount}`);
  return keccak256(concat([COUNT_PREFIX, merkleRoot.toLowerCase(), toBeHex(n, 8)]));
}

function hashPair(a, b) {
  // toLowerCase is load bearing. Solidity compares bytes32 numerically and
  // this compares hex strings; the two agree only because 0-9 sorts before
  // a-f in ASCII and both sides are lowercase. Do not "simplify" it away.
  return a.toLowerCase() <= b.toLowerCase()
    ? keccak256(concat([NODE_PREFIX, a, b]))
    : keccak256(concat([NODE_PREFIX, b, a]));
}

/**
 * @param {string[]} leaves 0x prefixed 32 byte hashes
 * @returns {{root: string, levels: string[][]}}
 */
function buildTree(leaves) {
  if (!Array.isArray(leaves)) throw new Error('leaves must be an array');
  if (leaves.length === 0) {
    // A period with no rounds is stated rather than implied by a zero, because
    // a zero is also what an epoch that was never anchored reads as.
    return { root: EMPTY_PERIOD, merkleRoot: EMPTY_PERIOD, count: 0, levels: [[]] };
  }
  const seen = new Set();
  for (const l of leaves) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(l)) throw new Error(`bad leaf: ${l}`);
    const k = l.toLowerCase();
    if (seen.has(k)) {
      // Duplicate leaves let one record stand in for another during
      // verification. Reject at build time rather than ship a weak tree.
      throw new Error(`duplicate leaf: ${l}`);
    }
    seen.add(k);
  }

  // Pad up to a power of two. `padded.length` is the smallest power of two at
  // or above the leaf count, so every level is even and no node is ever paired
  // with itself.
  const padded = leaves.map((l) => l.toLowerCase());
  let width = 1;
  while (width < padded.length) width *= 2;
  while (padded.length < width) padded.push(EMPTY_LEAF);

  const levels = [padded];
  while (levels[levels.length - 1].length > 1) {
    const cur = levels[levels.length - 1];
    const next = [];
    for (let i = 0; i < cur.length; i += 2) {
      next.push(hashPair(cur[i], cur[i + 1]));
    }
    levels.push(next);
  }
  const merkleRoot = levels[levels.length - 1][0];
  // `root` is what gets anchored: the Merkle root with the leaf count folded
  // in. `merkleRoot` is kept for anyone who wants to inspect the tree itself.
  return { root: commit(merkleRoot, leaves.length), merkleRoot, count: leaves.length, levels };
}

/** Sibling path for the leaf at `index`. */
function getProof(levels, index) {
  if (!Number.isInteger(index) || index < 0 || index >= levels[0].length) {
    throw new Error('index out of range');
  }
  const proof = [];
  let idx = index;
  for (let l = 0; l < levels.length - 1; l++) {
    const cur = levels[l];
    // Every level is a power of two, so the sibling always exists.
    proof.push(cur[idx ^ 1]);
    idx = Math.floor(idx / 2);
  }
  return proof;
}

/**
 * The depth a proof must have for a tree of `recordCount` leaves.
 *
 * The same arithmetic as HCOWLedger._proofDepth, ceil(log2(n)), which is exact
 * because buildTree pads to a power of two. Written as its own function
 * because verifyProof needs it and because a fixed depth is what makes the
 * length check below meaningful.
 */
function depthOf(recordCount) {
  let n = recordCount, d = 0;
  while (n > 1) { n = (n >> 1) + (n & 1); d += 1; }
  return d;
}

/**
 * Same algorithm the contract runs. Use this to check before publishing.
 *
 * `recordCount` is required, not optional. It is part of what the anchored
 * value commits to, and a default would let a caller verify against a count
 * the anchor never stated, which is the whole defect this fold exists to
 * close.
 *
 * The three guards below are not decoration and this function shipped without
 * them, which made the sentence at the top of this comment false:
 *
 *   - A proof of the wrong LENGTH lets an internal node be presented as a
 *     leaf. Folding stops early and the shortened path still reaches the root,
 *     so `verifyProof(tree.merkleRoot, [], tree.root, 4)` returned true. The
 *     tree is padded to a power of two, so the correct depth is fixed by the
 *     count alone and any other length is a forgery.
 *   - EMPTY_LEAF is the padding filler. It is genuinely in the tree, with a
 *     genuine proof, so without an explicit rejection a verifier will confirm
 *     that a record which never existed is part of the anchored set.
 *   - A zero root, or EMPTY_PERIOD, is an absence or a positive statement of
 *     emptiness. Neither contains records.
 *
 * HCOWLedger._verify rejects all three (contracts/HCOWLedger.sol, `_verify`),
 * so the chain was never fooled by any of them. This function is the one the
 * README offers as the reference implementation, which is the reason it
 * mattered: a third party checking a receipt off chain got a different answer
 * from the one the chain gives.
 */
function verifyProof(leaf, proof, root, recordCount) {
  if (recordCount === undefined) throw new Error('verifyProof needs the record count');
  const r = String(root).toLowerCase();
  if (recordCount === 0) return false;
  if (r === ZERO_ROOT || r === EMPTY_PERIOD.toLowerCase()) return false;
  if (proof.length !== depthOf(recordCount)) return false;
  const l = String(leaf).toLowerCase();
  if (l === EMPTY_LEAF.toLowerCase()) return false;
  let h = l;
  for (const p of proof) h = hashPair(h, p);
  return commit(h, recordCount) === r;
}

const ZERO_ROOT = '0x' + '0'.repeat(64);

module.exports = {
  NODE_PREFIX, COUNT_PREFIX, EMPTY_PERIOD, EMPTY_LEAF,
  buildTree, getProof, verifyProof, depthOf, hashPair, commit };
