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
  // A missing browser binary is a setup problem, not a defect, and it should
  // read as one. `npm ci` installs the playwright package but not the browser
  // it drives, so on a fresh clone this step used to die with a stack trace
  // three steps into `npm run test:all`. It still FAILS - a check that quietly
  // skips itself is the shape of defect this repository keeps finding - but it
  // now says which command fixes it.
  let b;
  try {
    b = await chromium.launch({ args:['--no-sandbox'] });
  } catch (e) {
    console.log('FAIL  the browser this check drives is not installed');
    console.log('      run:  npx playwright install chromium');
    console.log('      (npm ci installs the playwright package, not the browser)');
    console.log('      original error: ' + String(e.message || e).split('\n')[0]);
    process.exit(1);
  }
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
    // The page folds the record count in exactly as the contract does, so the
    // comparison is against the anchored value, not the bare Merkle root.
    const wRoot = await pg.evaluate(([l,p,n]) => commit(rootFrom(l,p),n), [leaves[idx], proof, N]);
    if (wRoot.toLowerCase() !== t.root.toLowerCase()) { bad++; console.log('root mismatch at', idx, wRoot, t.root); }
    const wWrongCount = await pg.evaluate(([l,p,n]) => commit(rootFrom(l,p),n), [leaves[idx], proof, N + 1]);
    if (wWrongCount.toLowerCase() === t.root.toLowerCase()) {
      bad++; console.log('page accepted a restated record count at', idx);
    }
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

  // ---- a lying RPC must not be able to grant a pass ----
  //
  // The page invites the visitor to point it at any endpoint, which is the
  // honest offer and also means one HTTP server was, for a while, the single
  // most trusted component in the whole verification. It granted a pass on
  // eth_call returning 1, and threw away the root it had just computed itself.
  // Both must agree now. This drives the page with an endpoint that says yes
  // to everything and asserts the verdict is not a pass.
  {
    const good = rec({ roundId: 'r-liar' });
    const gl = leafHash(good, KIND);
    const gt = buildTree([gl, leafHash(rec({ roundId: 'r-other' }), KIND)]);
    const gp = getProof(gt.levels, 0);

    // eth_call -> 1 (accepted), getEpoch -> a plausible tuple with a root that
    // is NOT what the receipt computes to. A page that trusts the node alone
    // calls this genuine.
    const fakeRoot = '0x' + 'ab'.repeat(32);
    await pg.route('**/liar-rpc', (route) => {
      const body = JSON.parse(route.request().postData());
      const sel = body.params[0].data.slice(0, 10);
      const w = (h) => h.replace(/^0x/, '').padStart(64, '0');
      const result = sel === '0x7a05560c'
        ? '0x' + w('0x1')                                   // verifyEpochRecord -> true
        : '0x' + w(fakeRoot) + w('0x' + (2).toString(16))   // getEpoch: root, recordCount
                + w('0x' + Math.floor(Date.now() / 1000).toString(16)); // anchoredAt
      route.fulfill({ status: 200, contentType: 'application/json',
                      body: JSON.stringify({ jsonrpc: '2.0', id: body.id, result }) });
    });

    await pg.evaluate(([receipt, rpc, addr]) => {
      document.getElementById('receipt').value = receipt;
      document.getElementById('rpc').value = rpc;
      document.getElementById('addr').value = addr;
    }, [JSON.stringify({ epoch: 0, kind: KIND, record: good, proof: gp }),
        'https://example.invalid/liar-rpc',
        '0x' + '11'.repeat(20)]);
    await pg.click('#go');
    await pg.waitForFunction(() => document.getElementById('verdict').className !== 'verdict');
    // verdict() writes 'verdict ok' or 'verdict no'. Checking for 'pass' here
    // matched neither, so the assertion could never have fired: it is the
    // check-that-checks-nothing shape, caught by reverting the fix and
    // watching which half of this block noticed.
    const cls = await pg.evaluate(() => document.getElementById('verdict').className);
    if (cls.split(/\s+/).includes('ok')) {
      bad++;
      console.log('the page granted a PASS on a node that returned a root the receipt does not produce');
    }
    const said = await pg.evaluate(() => document.getElementById('checks').textContent);
    if (!said.includes('not telling the truth')) {
      bad++;
      console.log('the page did not name the endpoint as the problem:', said.slice(0, 200));
    }
    await pg.unroute('**/liar-rpc');
  }

  console.log('page errors:', errs.length ? errs : 'none');
  console.log(bad === 0
    ? `web page matches lib on ${vectors.length} seeded vectors, 1 skill vector, 7 proofs, 4 rejection paths, and refuses a lying RPC`
    : `MISMATCHES: ${bad}`);
  await b.close();
  process.exit(bad ? 1 : 0);
})();
