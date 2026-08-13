'use strict';
/**
 * Merkle tree with sorted pair hashing, matching HCOWLedger._verify.
 *
 * Sorted pairs mean a proof is just a list of sibling hashes with no
 * direction bits, which keeps proofs small and verification trivial in
 * any language. An odd node at a level is promoted unchanged.
 */

const { keccak256, concat } = require('ethers');

function hashPair(a, b) {
  return a.toLowerCase() <= b.toLowerCase()
    ? keccak256(concat([a, b]))
    : keccak256(concat([b, a]));
}

/**
 * @param {string[]} leaves 0x prefixed 32 byte hashes
 * @returns {{root: string, levels: string[][]}}
 */
function buildTree(leaves) {
  if (!Array.isArray(leaves)) throw new Error('leaves must be an array');
  if (leaves.length === 0) {
    return { root: '0x' + '0'.repeat(64), levels: [[]] };
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

  const levels = [leaves.map((l) => l.toLowerCase())];
  while (levels[levels.length - 1].length > 1) {
    const cur = levels[levels.length - 1];
    const next = [];
    for (let i = 0; i < cur.length; i += 2) {
      next.push(i + 1 < cur.length ? hashPair(cur[i], cur[i + 1]) : cur[i]);
    }
    levels.push(next);
  }
  return { root: levels[levels.length - 1][0], levels };
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
    const pair = idx ^ 1;
    if (pair < cur.length) proof.push(cur[pair]);
    idx = Math.floor(idx / 2);
  }
  return proof;
}

/** Same algorithm the contract runs. Use this to check before publishing. */
function verifyProof(leaf, proof, root) {
  let h = leaf.toLowerCase();
  for (const p of proof) h = hashPair(h, p);
  return h === root.toLowerCase();
}

module.exports = { buildTree, getProof, verifyProof, hashPair };
