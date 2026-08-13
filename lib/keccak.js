'use strict';
/**
 * Keccak-256, dependency free.
 *
 * The public verification page must not need a CDN. If verifying our data
 * required loading a script from somewhere, a sceptic would be right to
 * object. This is small enough to read end to end.
 */

const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

const ROT = [
   0n,  1n, 62n, 28n, 27n,
  36n, 44n,  6n, 55n, 20n,
   3n, 10n, 43n, 25n, 39n,
  41n, 45n, 15n, 21n,  8n,
  18n,  2n, 61n, 56n, 14n,
];

const M = (1n << 64n) - 1n;
const rotl = (x, n) => n === 0n ? x : ((x << n) | (x >> (64n - n))) & M;

function keccakF(A) {
  for (let round = 0; round < 24; round++) {
    // theta
    const C = new Array(5);
    for (let x = 0; x < 5; x++) C[x] = A[x] ^ A[x + 5] ^ A[x + 10] ^ A[x + 15] ^ A[x + 20];
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1n);
      for (let y = 0; y < 25; y += 5) A[x + y] ^= D;
    }
    // rho and pi
    const B = new Array(25).fill(0n);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(A[x + 5 * y], ROT[x + 5 * y]);
      }
    }
    // chi
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; x++) {
        A[x + y] = B[x + y] ^ (~B[((x + 1) % 5) + y] & M & B[((x + 2) % 5) + y]);
      }
    }
    // iota
    A[0] ^= RC[round];
  }
  return A;
}

/** @param {Uint8Array} msg @returns {Uint8Array} 32 bytes */
function keccak256Bytes(msg) {
  const RATE = 136;
  const padLen = RATE - (msg.length % RATE);
  const padded = new Uint8Array(msg.length + padLen);
  padded.set(msg);
  padded[msg.length] |= 0x01;          // keccak domain, not 0x06
  padded[padded.length - 1] |= 0x80;

  const A = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += RATE) {
    for (let i = 0; i < RATE / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      A[i] ^= lane;
    }
    keccakF(A);
  }

  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = A[i];
    for (let b = 0; b < 8; b++) { out[i * 8 + b] = Number(lane & 0xffn); lane >>= 8n; }
  }
  return out;
}

const hex = (b) => '0x' + Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

function hexToBytes(h) {
  const s = h.startsWith('0x') ? h.slice(2) : h;
  if (s.length % 2) throw new Error('odd hex length');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}

/** keccak256 over a UTF-8 string. */
const keccakUtf8 = (s) => hex(keccak256Bytes(new TextEncoder().encode(s)));
/** keccak256 over 0x prefixed hex. */
const keccakHex = (h) => hex(keccak256Bytes(hexToBytes(h)));

module.exports = { keccak256Bytes, keccakUtf8, keccakHex, hexToBytes, bytesToHex: hex };
