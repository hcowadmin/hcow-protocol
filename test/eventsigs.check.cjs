'use strict';
/**
 * The indexer's event declarations are hand written and the contracts change.
 * A declaration the contract does not emit is a row that never appears; a
 * declaration whose indexed flags drift produces the identical topic0 with an
 * incompatible layout, so the decode throws and the indexer stops advancing
 * on that block for good. Both have happened. Check them against the compiled
 * ABIs rather than against a comment.
 */
const fs = require('fs');
const { Interface } = require('ethers');

const SRC = 'supabase/functions/index-events/index.ts';
const src = fs.readFileSync(SRC, 'utf8');

function block(name) {
  const m = src.match(new RegExp(name + ' = \\[([\\s\\S]*?)\\n\\];'));
  if (!m) throw new Error(`could not find ${name} in ${SRC}`);
  return [...m[1].matchAll(/"(event [^"]+)"/g)].map((x) => x[1]);
}

const DECL = {
  HCOWProfitShare: block('PROFIT_SHARE_EVENTS'),
  HCOWStaking: block('STAKING_EVENTS'),
  HCOWLedger: block('LEDGER_EVENTS'),
};

/**
 * Which list is paired with which address in SOURCES. The defect this file
 * exists to catch was a correct list attached to the wrong address, so
 * checking the lists against the ABIs is only half the job: the pairing has to
 * be checked too, or three governance events sit in a list that is filtered
 * out by address and never appear anywhere.
 */
const EXPECTED_PAIRS = {
  PROFIT_SHARE: 'PROFIT_SHARE_EVENTS',
  STAKING: 'STAKING_EVENTS',
  LEDGER: 'LEDGER_EVENTS',
};

const sigOf = (name, inputs) => `${name}(${inputs.map((i) => i.type).join(',')})`;
let bad = 0;

for (const [contract, declared] of Object.entries(DECL)) {
  const art = JSON.parse(
    fs.readFileSync(`artifacts/contracts/${contract}.sol/${contract}.json`, 'utf8'));
  const real = new Map(
    art.abi.filter((x) => x.type === 'event').map((e) => [sigOf(e.name, e.inputs), e]));
  const before = bad;
  console.log(`=== ${contract} ===`);

  const declIface = new Interface(declared);
  const declSigs = new Set();
  for (const f of declIface.fragments) {
    const sig = sigOf(f.name, f.inputs);
    declSigs.add(sig);
    const r = real.get(sig);
    if (!r) { console.log(`  DECLARED BUT NEVER EMITTED  ${sig}`); bad++; continue; }
    const d = f.inputs.map((i) => !!i.indexed).join(',');
    const g = r.inputs.map((i) => !!i.indexed).join(',');
    if (d !== g) { console.log(`  INDEXED MISMATCH  ${sig}: declared [${d}] actual [${g}]`); bad++; }
  }
  for (const sig of real.keys()) {
    if (!declSigs.has(sig)) { console.log(`  EMITTED BUT NOT INDEXED  ${sig}`); bad++; }
  }
  if (bad === before) console.log('  ok');
}

console.log('=== SOURCES pairing ===');
{
  const m = src.match(/const SOURCES = \[([\s\S]*?)\n\]/);
  if (!m) { console.log('  could not find SOURCES'); bad++; }
  else {
    const pairs = [...m[1].matchAll(/address:\s*([A-Z_]+),\s*iface:\s*new Interface\(([A-Z_]+)\)/g)]
      .map(([, addr, list]) => [addr, list]);
    for (const [addr, want] of Object.entries(EXPECTED_PAIRS)) {
      const got = pairs.find(([a]) => a === addr);
      if (!got) { console.log(`  MISSING SOURCE  ${addr}`); bad++; }
      else if (got[1] !== want) {
        console.log(`  WRONG LIST  ${addr} is paired with ${got[1]}, expected ${want}`); bad++;
      }
    }
    for (const [addr, list] of pairs) {
      if (!EXPECTED_PAIRS[addr]) { console.log(`  UNEXPECTED SOURCE  ${addr} -> ${list}`); bad++; }
    }
    if (pairs.length === Object.keys(EXPECTED_PAIRS).length) console.log('  ok');
  }
}

console.log(bad
  ? `\n${bad} problem(s) between the indexer and the compiled ABIs`
  : '\nevent declarations match the compiled ABIs');
process.exit(bad ? 1 : 0);
