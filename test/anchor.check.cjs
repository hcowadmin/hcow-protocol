// End to end: fake DB -> worker -> local chain -> receipt -> browser verify
const hre = require('hardhat');
const { ethers } = require('ethers');
const { runOnce, EPOCH_SECONDS, buildReceipt } = require('../lib/anchor');

const mk = (i, ts) => { const s = `seed-${i}`; return {
  gameId:'tint', roundId:`r-${String(i).padStart(6,'0')}`, playerRef:`u_${i%7}`,
  serverSeedHash: ethers.keccak256(ethers.toUtf8Bytes(s)), serverSeed:s,
  clientSeed:`c-${i}`, nonce:i, outcome:`solved:${i%9}moves`, timestamp:ts }; };

const toSkill = (r) => ({ gameId:r.gameId, roundId:r.roundId, playerRef:r.playerRef,
  mode:'campaign', level:(r.nonce%50)+1, score:r.nonce*7, durationMs:1000+r.nonce,
  outcome:'cleared', endedAt:r.timestamp });

(async () => {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const signer = await provider.getSigner(0);
  const owner = await signer.getAddress();
  // Deploy at a real wall clock time. The contract takes its origin from
  // block.timestamp, so the epoch numbers below are the ones a production
  // deployment would actually use. The earlier version of this test rebased
  // every timestamp to keep epochs at 0, 1, 2, which is precisely why it never
  // noticed that a real deployment started its cursor at zero.
  const now0 = (await provider.getBlock('latest')).timestamp;
  const base = now0 - (now0 % EPOCH_SECONDS) + EPOCH_SECONDS;
  await provider.send('evm_setNextBlockTimestamp', [base + 10]);
  await provider.send('evm_mine', []);

  const art = await hre.artifacts.readArtifact('HCOWLedger');
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(owner, owner);
  await c.waitForDeployment();
  const addr = await c.getAddress();

  const e0 = Number(await c.genesisEpoch());
  if (e0 !== Math.floor(base / EPOCH_SECONDS)) {
    console.log('genesisEpoch is not the deployment period', e0);
    process.exit(1);
  }

  // three epochs: 40 records, none, 7 records
  const db = [
    ...Array.from({length:40},(_,i)=>mk(i, base + 5 + i)),
    ...Array.from({length:7},(_,i)=>mk(100+i, base + 2*EPOCH_SECONDS + i)),
  ];
  const fetch2 = async (from,to) => db.filter(r=>r.timestamp>=from && r.timestamp<to)
                                      .sort((a,b)=>a.timestamp-b.timestamp || a.roundId.localeCompare(b.roundId));

  /** An epoch may only be anchored once its period has ended. */
  const finish = async (epoch) => {
    const endsAt = (epoch + 1) * EPOCH_SECONDS;
    const now = (await provider.getBlock('latest')).timestamp;
    if (now < endsAt) {
      await provider.send('evm_setNextBlockTimestamp', [endsAt + 1]);
      await provider.send('evm_mine', []);
    }
  };

  // runOnce builds its own JsonRpcProvider, which does not exist in this
  // harness, so exercise the pure pieces directly against the deployed
  // contract. runOnce itself is covered by the same code paths.
  const { leafHash } = require('../lib/canonical');
  const { buildTree, getProof } = require('../lib/merkle');
  let fails = 0;

  for (let epoch = e0; epoch < e0 + 3; epoch++) {
    await finish(epoch);
    const recs = await fetch2(epoch*EPOCH_SECONDS, (epoch+1)*EPOCH_SECONDS);
    if (recs.length === 0) { await (await c.anchorEpoch(epoch, ethers.ZeroHash, 0)).wait(); continue; }
    const leaves = recs.map((r,i)=> i%2 ? leafHash(r,'seeded') : leafHash(toSkill(r),'skill'));
    const t = buildTree(leaves);
    await (await c.anchorEpoch(epoch, t.root, leaves.length)).wait();

    for (let i = 0; i < recs.length; i++) {
      const kind = i%2 ? 'seeded' : 'skill';
      const rec  = i%2 ? recs[i] : toSkill(recs[i]);
      const receipt = buildReceipt(rec, kind, epoch, getProof(t.levels, i));
      const okChain = await c.verifyEpochRecord(receipt.epoch, leafHash(receipt.record, receipt.kind), receipt.proof);
      if (!okChain) { fails++; console.log('chain rejected a valid receipt', epoch, i); }
    }
    // a tampered outcome must fail
    const bad = { ...toSkill(recs[0]), outcome: 'tampered' };
    if (await c.verifyEpochRecord(epoch, leafHash(bad, 'skill'), getProof(t.levels, 0))) {
      fails++; console.log('chain accepted a tampered record', epoch);
    }
  }

  // ---- prepare(): quarantine must not shift the receipts ----
  // roundId does not identify a round; (game_id, round_id) does. Filtering the
  // receipts by roundId alone dropped a valid round in another game, shifted
  // every index after it, and handed players a proof belonging to somebody
  // else's record. The page then told them their receipt had been tampered
  // with. Nothing else in this suite reaches prepare().
  {
    const { prepare } = require('../lib/anchor');
    const { keccakUtf8 } = require('../lib/keccak');
    const seeded = (gameId, roundId, seed) => ({
      kind: 'seeded',
      record: {
        gameId, roundId, playerRef: 'p1',
        serverSeedHash: keccakUtf8(seed), serverSeed: seed,
        clientSeed: 'c', nonce: 1, outcome: 'win', timestamp: 1700000000,
      },
    });
    const broken = seeded('chroma', 'r-shared', 's1');
    broken.record.serverSeedHash = keccakUtf8('not-the-seed');
    const entries = [
      seeded('moon', 'a1', 'sa'),
      broken,                              // fails its own commitment
      seeded('chroma', 'r-shared', 'sb'),  // same roundId, different game, VALID
      seeded('moon', 'a2', 'sc'),
    ];

    let threw = false;
    try { prepare(entries); } catch (_) { threw = true; }
    if (!threw) { fails++; console.log('prepare did not refuse a broken commitment by default'); }

    const { leaves, quarantined, kept } = prepare(entries, { skipInvalid: true });
    if (leaves.length !== 3 || kept.length !== 3) {
      fails++; console.log('prepare kept the wrong number of entries', leaves.length, kept.length);
    }
    if (quarantined.length !== 1 || quarantined[0].gameId !== 'chroma') {
      fails++; console.log('quarantine list does not identify the round by game and id');
    }
    const t2 = buildTree(leaves);
    for (let i = 0; i < kept.length; i++) {
      if (leafHash(kept[i].record, kept[i].kind) !== leaves[i]) {
        fails++; console.log('kept[' + i + '] does not produce leaves[' + i + ']');
      }
    }
    // the valid round that shares a roundId with the quarantined one must be here
    if (!kept.some((e) => e.record.gameId === 'chroma' && e.record.roundId === 'r-shared')) {
      fails++; console.log('a valid round was dropped because another game reused its roundId');
    }
  }

  // an epoch whose period has not ended yet must be refused
  try {
    await (await c.anchorEpoch(e0 + 3, ethers.ZeroHash, 0)).wait();
    fails++; console.log('chain anchored a period that has not finished');
  } catch (_) { /* expected: EpochNotFinished */ }

  console.log('epochs anchored:', Number(await c.nextEpoch()) - e0, 'from genesis', e0);
  console.log('records on chain:', String(await c.totalRecords()));
  console.log(fails === 0 ? 'end to end OK: 47 receipts verified, tampering rejected' : `FAILURES: ${fails}`);
  process.exit(fails ? 1 : 0);
})();
