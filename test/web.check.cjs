// Confirms the browser page computes byte-identical results to lib/.
const { chromium } = require('playwright');
const { leafHash, canonicalize } = require('../lib/canonical');
const KIND='seeded';
const { buildTree, getProof } = require('../lib/merkle');
const { ethers } = require('ethers');

const rec = (o={}) => { const s=o.serverSeed||'seed-abc-123'; return {
  gameId:'tint', roundId:'r-000001', playerRef:'u_8f21c4',
  serverSeedHash: ethers.keccak256(ethers.toUtf8Bytes(s)), serverSeed:s,
  clientSeed:'c-99', nonce:1, outcome:'solved:3moves', timestamp:1755000000, ...o }; };

(async () => {
  const b = await chromium.launch({ args:['--no-sandbox'] });
  const pg = await b.newPage();
  const errs = []; pg.on('pageerror', e => errs.push(String(e)));
  await pg.goto('file:///home/claude/ledger/web/verify.html');

  // vectors: plain, unicode, tab/newline injection, big tree
  const vectors = [
    rec(),
    rec({ outcome:'한글 결과 🐮' }),
    rec({ gameId:'tint\tr-000001' }),
    rec({ playerRef:'a\\b\nc' }),
    rec({ nonce:0, timestamp:0 + 1 }),
  ];
  let bad = 0;
  for (const [i,r] of vectors.entries()) {
    const [wCanon, wLeaf] = await pg.evaluate(x => [canonical(x,'seeded'), leafOf(x,'seeded')], r);
    if (wCanon !== canonicalize(r,KIND)) { bad++; console.log('canonical mismatch', i); }
    if (wLeaf.toLowerCase() !== leafHash(r,KIND).toLowerCase()) { bad++; console.log('leaf mismatch', i, wLeaf, leafHash(r,KIND)); }
  }

  const N = 257;
  const recs = Array.from({length:N},(_,i)=>rec({roundId:`r-${i}`,nonce:i,serverSeed:`s-${i}`}));
  const leaves = recs.map(r=>leafHash(r,KIND));
  const t = buildTree(leaves);
  for (const idx of [0,1,2,127,128,255,256]) {
    const proof = getProof(t.levels, idx);
    const wRoot = await pg.evaluate(([l,p]) => rootFrom(l,p), [leaves[idx], proof]);
    if (wRoot.toLowerCase() !== t.root.toLowerCase()) { bad++; console.log('root mismatch at', idx, wRoot, t.root); }
  }

  // rejection paths must behave the same
  const rejects = [
    ['extra field', {...rec(), extra:'x'}],
    ['missing field', (()=>{const r=rec(); delete r.outcome; return r;})()],
    ['string nonce', {...rec(), nonce:'1'}],
  ];
  for (const [name, r] of rejects) {
    const threw = await pg.evaluate(x => { try { leafOf(x,'seeded'); return false; } catch(e){ return true; } }, r);
    if (!threw) { bad++; console.log('page failed to reject:', name); }
  }

  // skill kind must match too
  const sk = { gameId:'tint', roundId:'r-1', playerRef:'p_1', mode:'campaign',
               level:12, score:8400, durationMs:64210, outcome:'cleared', endedAt:1755000000 };
  const wSkill = await pg.evaluate(x => leafOf(x,'skill'), sk);
  if (wSkill.toLowerCase() !== leafHash(sk,'skill').toLowerCase()) { bad++; console.log('skill leaf mismatch'); }
  const kindMix = await pg.evaluate(x => { try { leafOf(x,'seeded'); return false; } catch(e){ return true; } }, sk);
  if (!kindMix) { bad++; console.log('page failed to reject kind mismatch'); }

  console.log('page errors:', errs.length ? errs : 'none');
  console.log(bad === 0
    ? `web page matches lib on ${vectors.length} seeded vectors, 1 skill vector, 7 proofs, 4 rejection paths`
    : `MISMATCHES: ${bad}`);
  await b.close();
  process.exit(bad ? 1 : 0);
})();
