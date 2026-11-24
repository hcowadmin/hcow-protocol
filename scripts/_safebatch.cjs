'use strict';
const { ethers } = require('ethers');

// ---- Safe Transaction Builder file format -------------------------------
// The checksum is the one the Transaction Builder app computes
// (safe-react-apps, tx-builder lib/checksum.ts): keccak256 of a key-sorted
// serialisation of the batch with meta.name nulled and no checksum field.
// If it ever disagrees, the app shows a warning and still loads the batch.
const stringifyReplacer = (_, v) => (v === undefined ? null : v);
function serialize(j) {
  if (Array.isArray(j)) return `[${j.map(serialize).join(',')}]`;
  if (typeof j === 'object' && j !== null) {
    const keys = Object.keys(j).sort();
    let acc = `{${JSON.stringify(keys, stringifyReplacer)}`;
    for (const k of keys) acc += `${serialize(j[k])},`;
    return `${acc}}`;
  }
  return `${JSON.stringify(j, stringifyReplacer)}`;
}
function batchFile(safe, name, description, txs) {
  const b = {
    version: '1.0',
    chainId: '56',
    createdAt: Date.now(),
    meta: { name, description, txBuilderVersion: '1.18.0', createdFromSafeAddress: safe, createdFromOwnerAddress: '' },
    transactions: txs.map((t) => ({ to: t.to, value: '0', data: t.data, contractMethod: null, contractInputsValues: null })),
  };
  const checksum = ethers.keccak256(ethers.toUtf8Bytes(serialize({ ...b, meta: { ...b.meta, name: null } })));
  b.meta.checksum = checksum;
  return b;
}

module.exports = { batchFile, serialize };
