'use strict';
// Everything after the four contracts exist. Read-only: signs nothing.
//
//   npx hardhat run scripts/mainnet-postdeploy.cjs --network bsc
//
// 1. Reads every role, token and wiring value back from the chain and compares
//    it with config/mainnet.json and deployments/bsc.json.
// 2. Checks each creation transaction byte for byte against the compiled
//    artifact plus the expected constructor arguments.
// 3. Writes, under out/mainnet/:
//      bscscan/<Contract>/standard-input.json + constructor-args.txt
//        (recompiled here from exactly those sources; must reproduce the
//         deployed creation bytecode or the file is not written)
//      safe/*.json   Safe{Wallet} Transaction Builder batches, one per Safe,
//                    each first transaction simulated from that Safe
//      dapp.env.mainnet, _headers.mainnet   for the app.hash-cow.io build
//      supabase-secrets.txt                  for the event indexer
//      SUMMARY.txt

const {
  fs, path, ethers, ROOT, ERC20, loadConfig, provider, readRecord, addr, fmt, hre,
} = require('./_mainnet.cjs');

const OUT = path.join(ROOT, 'out', 'mainnet');
const MIN_POOL_SHARES = 1_000_000n * 10n ** 18n;

const art = (name) => hre.artifacts.readArtifact(name);

const { batchFile } = require('./_safebatch.cjs');

async function main() {
  const cfg = loadConfig();
  const p = provider();
  const net = await p.getNetwork();
  if (net.chainId !== 56n) throw new Error(`chainId ${net.chainId}, expected 56`);
  const rec = readRecord();
  if (!rec) throw new Error('no deployment record. Run mainnet-deploy.cjs first.');
  const A = rec.addresses;
  const roles = {};
  for (const k of ['owner', 'anchorer', 'settler', 'gameCompany', 'team', 'funder']) roles[k] = addr(k, cfg.roles[k]);
  const hcowA = addr('HCOW', cfg.tokens.HCOW);
  const usdtA = addr('USDT', cfg.tokens.USDT);

  const fails = [];
  const check = (label, got, want) => {
    const okk = String(got).toLowerCase() === String(want).toLowerCase();
    console.log(`  ${okk ? 'ok ' : 'BAD'}  ${label.padEnd(34)} ${got}`);
    if (!okk) fails.push(`${label}: ${got}, expected ${want}`);
  };

  // ---- 1. state read-back -------------------------------------------------
  console.log('read-back');
  const L = new ethers.Contract(A.HCOWLedger, (await art('HCOWLedger')).abi, p);
  const S = new ethers.Contract(A.HCOWStaking, (await art('HCOWStaking')).abi, p);
  const V = new ethers.Contract(A.HCOWRewardVault, (await art('HCOWRewardVault')).abi, p);
  const P = new ethers.Contract(A.HCOWProfitShare, (await art('HCOWProfitShare')).abi, p);
  check('record HCOW', A.HCOW, hcowA);
  check('record USDT', A.USDT, usdtA);
  for (const [k, v] of Object.entries(roles)) check(`record role ${k}`, rec.roles[k], v);
  check('Ledger.owner', await L.owner(), roles.owner);
  check('Ledger.isAnchorer(anchorer)', await L.isAnchorer(roles.anchorer), true);
  check('Ledger.anchorerCount', await L.anchorerCount(), 1);
  check('Staking.owner', await S.owner(), roles.owner);
  check('Staking.hcow', await S.hcow(), hcowA);
  check('Staking.rewardFunder', await S.rewardFunder(), A.HCOWRewardVault);
  check('Vault.owner', await V.owner(), roles.owner);
  check('Vault.keeper', await V.keeper(), roles.funder);
  check('Vault.staking', await V.staking(), A.HCOWStaking);
  check('Vault.hcow', await V.hcow(), hcowA);
  check('Vault.isLive', await V.isLive(), true);
  check('ProfitShare.owner', await P.owner(), roles.owner);
  check('ProfitShare.settler', await P.settler(), roles.settler);
  check('ProfitShare.gameCompany', await P.gameCompany(), roles.gameCompany);
  check('ProfitShare.team', await P.team(), roles.team);
  check('ProfitShare.hcow', await P.hcow(), hcowA);
  check('ProfitShare.usdt', await P.usdt(), usdtA);
  check('ProfitShare.rewardVault', await P.rewardVault(), A.HCOWRewardVault);
  check('ProfitShare.minPoolShares', await P.minPoolShares(), MIN_POOL_SHARES);
  check('ProfitShare.nextEpoch', await P.nextEpoch(), 0);
  for (const c of ['HCOWLedger', 'HCOWStaking', 'HCOWRewardVault', 'HCOWProfitShare']) {
    for (const who of ['pendingOwner']) {
      const k = { HCOWLedger: L, HCOWStaking: S, HCOWRewardVault: V, HCOWProfitShare: P }[c];
      check(`${c}.${who}`, await k[who](), ethers.ZeroAddress);
    }
  }

  // ---- 2. creation bytecode ----------------------------------------------
  console.log('\ncreation transactions');
  const ctor = {
    HCOWLedger: [roles.owner, roles.anchorer],
    HCOWStaking: [hcowA, roles.owner, A.HCOWRewardVault],
    HCOWRewardVault: [hcowA, A.HCOWStaking, roles.owner, roles.funder],
    HCOWProfitShare: [hcowA, usdtA, roles.owner, roles.settler, roles.gameCompany, roles.team, MIN_POOL_SHARES, A.HCOWRewardVault],
  };
  const encoded = {};
  for (const [name, args] of Object.entries(ctor)) {
    const a = await art(name);
    const iface = new ethers.Interface(a.abi);
    encoded[name] = iface.encodeDeploy(args);
    const tx = await p.getTransaction(rec.deploymentTxs[name]);
    const want = a.bytecode + encoded[name].slice(2);
    const same = tx && tx.data.toLowerCase() === want.toLowerCase() && !tx.to;
    console.log(`  ${same ? 'ok ' : 'BAD'}  ${name.padEnd(16)} tx ${rec.deploymentTxs[name]}  ${same ? 'bytecode + args identical' : 'MISMATCH'}`);
    if (!same) fails.push(`${name} creation input does not match artifact + expected args`);
    const code = await p.getCode(A[name]);
    if (code === '0x') fails.push(`${name} has no code at ${A[name]}`);
  }

  // ---- 3a. BscScan inputs -------------------------------------------------
  console.log('\nBscScan verification inputs');
  const solc = require('solc-0834');
  const biDir = path.join(ROOT, 'artifacts', 'build-info');
  const files = fs.readdirSync(biDir).map((f) => JSON.parse(fs.readFileSync(path.join(biDir, f), 'utf8')));
  for (const name of Object.keys(ctor)) {
    const src = `contracts/${name}.sol`;
    const bi = files.find((b) => b.output.contracts[src] && b.output.contracts[src][name]);
    if (!bi) { fails.push(`no build-info for ${name}`); continue; }
    const meta = JSON.parse(bi.output.contracts[src][name].metadata);
    const sources = {};
    for (const k of Object.keys(meta.sources)) sources[k] = { content: bi.input.sources[k].content };
    const input = {
      language: 'Solidity',
      sources,
      settings: {
        optimizer: bi.input.settings.optimizer,
        evmVersion: bi.input.settings.evmVersion,
        outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'] } },
      },
    };
    const out = JSON.parse(solc.compile(JSON.stringify(input)));
    const errs = (out.errors || []).filter((e) => e.severity === 'error');
    const bc = out.contracts && out.contracts[src] && out.contracts[src][name] && out.contracts[src][name].evm.bytecode.object;
    const a = await art(name);
    const same = !errs.length && bc && ('0x' + bc).toLowerCase() === a.bytecode.toLowerCase();
    console.log(`  ${same ? 'ok ' : 'BAD'}  ${name.padEnd(16)} ${Object.keys(sources).length} sources, recompiled ${same ? 'identical' : 'DIFFERENT'}`);
    if (!same) { fails.push(`${name} standard input does not reproduce the artifact`); continue; }
    const dir = path.join(OUT, 'bscscan', name);
    fs.mkdirSync(dir, { recursive: true });
    delete input.settings.outputSelection;
    input.settings.outputSelection = { '*': { '*': ['abi', 'evm.bytecode', 'evm.deployedBytecode', 'metadata'] } };
    fs.writeFileSync(path.join(dir, 'standard-input.json'), JSON.stringify(input, null, 1));
    fs.writeFileSync(path.join(dir, 'constructor-args.txt'), encoded[name].slice(2) + '\n');
    fs.writeFileSync(path.join(dir, 'README.txt'),
      `${name}  ${A[name]}\n` +
      'BscScan > Contract > Verify and Publish\n' +
      '  Compiler Type     Solidity (Standard-Json-Input)\n' +
      `  Compiler Version  v${solc.version().replace('.Emscripten.clang', '')}\n` +
      '  License           MIT\n' +
      '  File              standard-input.json\n' +
      '  Constructor Arguments (ABI-encoded)  contents of constructor-args.txt\n');
  }

  // ---- 3b. Safe batches ---------------------------------------------------
  console.log('\nSafe batches (first transaction of each simulated from its Safe)');
  const safeDir = path.join(OUT, 'safe');
  fs.mkdirSync(safeDir, { recursive: true });
  const H = new ethers.Interface(ERC20.concat(['function transfer(address,uint256) returns (bool)']));
  const amount = ethers.parseUnits(cfg.rewards.firstAmountHcow, 18);
  const dur = BigInt(cfg.rewards.durationSeconds);

  const reps = cfg.representatives.map((r) => ({
    id: ethers.encodeBytes32String(r.id), name: r.name, payout: addr(`rep ${r.id} payout`, r.payout),
    commissionBps: r.commissionBps, isFoundation: r.isFoundation,
  }));
  const batches = [
    { file: '01_treasury_register_representative.json', safe: roles.owner, label: 'Treasury Safe (owner)',
      name: 'HCOW staking: register representative',
      desc: 'HCOWStaking.registerRepresentative. Without at least one active representative nobody can stake.',
      txs: reps.map((r) => ({ to: A.HCOWStaking, data: S.interface.encodeFunctionData('registerRepresentative', [r.id, r.name, r.payout, r.commissionBps, r.isFoundation]) })) },
    { file: '02_incentives_send_rewards_to_vault.json', safe: addr('incentivesSafe', cfg.incentivesSafe), label: 'Incentives Safe',
      name: `HCOW rewards: ${cfg.rewards.firstAmountHcow} HCOW to reward vault`,
      desc: 'HCOW.transfer from the Community/Incentives Safe to HCOWRewardVault. The vault can only stream it into staking.',
      txs: [{ to: hcowA, data: H.encodeFunctionData('transfer', [A.HCOWRewardVault, amount]) }] },
    { file: '03_funder_start_reward_stream.json', safe: roles.funder, label: 'Funder Safe (vault keeper)',
      name: `HCOW rewards: stream ${cfg.rewards.firstAmountHcow} HCOW over ${Number(dur) / 86400} days`,
      desc: 'HCOWRewardVault.fund(amount, duration). Run only after batch 02 has executed.',
      txs: [{ to: A.HCOWRewardVault, data: V.interface.encodeFunctionData('fund', [amount, dur]) }] },
    { file: '04_settler_epoch0_zero_settlement.json', safe: roles.settler, label: 'Settler Safe',
      name: 'HCOW profit share: epoch 0, zero settlement',
      desc: 'settleEpoch(0, 0, 0, 0, 0). Moves no money. Proves the Settler Safe can settle, and starts the epoch clock.',
      txs: [{ to: A.HCOWProfitShare, data: P.interface.encodeFunctionData('settleEpoch', [0, 0, 0, 0, 0]) }] },
  ];
  for (const b of batches) {
    const f = batchFile(b.safe, b.name, b.desc, b.txs);
    fs.writeFileSync(path.join(safeDir, b.file), JSON.stringify(f, null, 2) + '\n');
    let sim = 'skipped (depends on an earlier batch)';
    if (b.file.startsWith('03')) {
      sim = 'run after 02';
    } else {
      try { await p.call({ from: b.safe, to: b.txs[0].to, data: b.txs[0].data }); sim = 'ok'; }
      catch (e) { sim = `REVERTS: ${e.shortMessage || e.message}`; if (!b.file.startsWith('02')) fails.push(`${b.file}: ${sim}`); }
    }
    console.log(`  ${b.file.padEnd(44)} ${b.label.padEnd(26)} ${b.safe}  sim ${sim}`);
  }

  // ---- 3c. app and indexer configuration --------------------------------
  const genesis = Math.min(...Object.values(rec.deploymentBlocks || {}));
  const d = cfg.dapp;
  const env = [
    `VITE_CHAIN_ID=56`, `VITE_CHAIN_NAME=${d.chainName}`, `VITE_RPC_URL=${d.rpcUrl}`,
    `VITE_EXPLORER_BASE=${d.explorerBase}`, `VITE_NATIVE_SYMBOL=${d.nativeSymbol}`,
    `VITE_HCOW_ADDRESS=${hcowA}`, `VITE_USDT_ADDRESS=${usdtA}`,
    `VITE_PROFIT_SHARE_ADDRESS=${A.HCOWProfitShare}`, `VITE_STAKING_ADDRESS=${A.HCOWStaking}`,
    `VITE_LEDGER_ADDRESS=${A.HCOWLedger}`, `VITE_FAUCET_ADDRESS=off`,
    `VITE_INDEXER_URL=${d.indexerUrl}`, `VITE_IS_TEST_DEPLOYMENT=false`,
  ];
  fs.writeFileSync(path.join(OUT, 'dapp.env.mainnet'), env.join('\n') + '\n');
  const rpcOrigin = new URL(d.rpcUrl).origin;
  fs.writeFileSync(path.join(OUT, '_headers.mainnet'),
    '# Mainnet build of app.hash-cow.io. Report-only, as on testnet.\n/*\n' +
    "  Content-Security-Policy-Report-Only: default-src 'self'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; " +
    `font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' ${rpcOrigin} ${d.indexerUrl}; ` +
    "object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\n");
  fs.writeFileSync(path.join(OUT, 'supabase-secrets.txt'), [
    `CHAIN_ID=56`, `RPC_URLS=${cfg.indexerRpcUrls.join(',')}`, `GENESIS_BLOCK=${genesis}`,
    `LEDGER_ADDRESS=${A.HCOWLedger}`, `PROFIT_SHARE_ADDRESS=${A.HCOWProfitShare}`,
    `STAKING_ADDRESS=${A.HCOWStaking}`, `REWARD_VAULT_ADDRESS=${A.HCOWRewardVault}`,
  ].join('\n') + '\n');

  const summary = [
    `HCOW protocol, BNB Chain mainnet  (written ${new Date().toISOString()})`,
    '',
    ...['HCOWLedger', 'HCOWStaking', 'HCOWRewardVault', 'HCOWProfitShare'].map((k) =>
      `${k.padEnd(16)} ${A[k]}  block ${rec.deploymentBlocks ? rec.deploymentBlocks[k] : '?'}`),
    '', `genesis block ${genesis}`, '',
    fails.length ? `FAILED CHECKS (${fails.length}):\n  ${fails.join('\n  ')}` : 'all checks passed',
  ].join('\n');
  fs.writeFileSync(path.join(OUT, 'SUMMARY.txt'), summary + '\n');
  console.log(`\n${summary}\n\nwritten to ${OUT}`);
  if (fails.length) process.exitCode = 1;
}

main().catch((e) => { console.error(e.shortMessage || e.message); process.exitCode = 1; });
