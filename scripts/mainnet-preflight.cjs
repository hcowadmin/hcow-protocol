'use strict';
// Read-only check of everything the mainnet deployment depends on.
//
//   DEPLOYER_ADDRESS=0x... npx hardhat run scripts/mainnet-preflight.cjs --network bsc
//
// Sends nothing and needs no key. mainnet-deploy.cjs runs the same checks
// again immediately before it deploys, so this is the "look before you leap"
// run that can be repeated as often as wanted.
//
// What it refuses, and why each one matters (none of these can be fixed after
// deployment without redeploying, or without a 2-of-3 owner transaction):
//   - a deployment record already exists      deploy.cjs has no re-run guard:
//                                             a second run deploys a second
//                                             estate and overwrites the record
//   - any role missing, malformed, duplicated, or equal to the deploy key
//   - owner / settler / gameCompany / team / funder not a Safe with
//     threshold >= 2 and exactly the three hardware wallet signers
//   - anchorer having code (it must be a plain hot wallet)
//   - HCOW not answering HashCow / HCOW / 18 / 200,000,000
//   - USDT not being BSC-USD
//   - the deploy key short of BNB for the four deployments

const {
  hre, fs, ethers, BSC_USD, SUPPLY, SAFE_ABI, ERC20,
  loadConfig, isLocal, provider, recordPath, addr, fmt,
} = require('./_mainnet.cjs');

// Measured on the local mainnet rehearsal (test/local-mainnet/rehearsal.sh):
// the four creations together used 9,177,109 gas. Rounded up, plus 50% below.
const DEPLOY_GAS = 10_000_000n;

async function preflight({ deployer, quiet = false } = {}) {
  const log = quiet ? () => {} : console.log;
  const fails = [];
  const warns = [];
  const fail = (m) => { fails.push(m); log(`  FAIL ${m}`); };
  const warn = (m) => { warns.push(m); log(`  warn ${m}`); };
  const ok = (m) => log(`  ok   ${m}`);

  const cfg = loadConfig();
  const p = provider();
  const net = await p.getNetwork();
  log(`network  ${hre.network.name}  chainId ${net.chainId}${isLocal() ? '  (LOCAL REHEARSAL)' : ''}`);

  if (net.chainId !== 56n) fail(`chainId is ${net.chainId}, expected 56`);
  else ok('chainId 56');

  if (fs.existsSync(recordPath())) {
    fail(`${recordPath()} already exists. deploy.cjs would deploy a second set and overwrite it. ` +
         'If the first deployment is real, stop here: the next step is mainnet-postdeploy.cjs.');
  } else ok('no deployment record yet');

  // ---- roles -------------------------------------------------------------
  log('\nroles');
  const roles = {};
  for (const k of ['owner', 'anchorer', 'settler', 'gameCompany', 'team', 'funder']) {
    try { roles[k] = addr(`roles.${k}`, cfg.roles[k]); }
    catch (e) { fail(e.message); }
  }
  const signers = cfg.safeSigners.map((s, i) => addr(`safeSigners[${i}]`, s));
  let me = null;
  if (deployer) {
    me = ethers.getAddress(deployer);
    const h = cfg.deployerHint || {};
    if (h.prefix && !(me.toLowerCase().startsWith(h.prefix.toLowerCase()) &&
                      me.toLowerCase().endsWith(h.suffix.toLowerCase()))) {
      warn(`deployer ${me} is not the ${h.prefix}…${h.suffix} wallet used in September`);
    }
  }
  const named = Object.entries(roles);
  for (let i = 0; i < named.length; i++) {
    for (let j = i + 1; j < named.length; j++) {
      if (named[i][1].toLowerCase() === named[j][1].toLowerCase()) {
        fail(`roles.${named[i][0]} and roles.${named[j][0]} are the same address`);
      }
    }
    if (me && named[i][1].toLowerCase() === me.toLowerCase()) fail(`roles.${named[i][0]} is the deploy key`);
    for (const s of signers) {
      if (named[i][1].toLowerCase() === s.toLowerCase()) fail(`roles.${named[i][0]} is a Safe signer, not a role address`);
    }
  }
  // The vesting Team tranche Safe looks like a natural TEAM_ADDRESS and is the
  // wrong one (see HCOW_Protocol_Roles_2026-09-18 §5). Guard the known pair.
  if (roles.team && roles.team.toLowerCase() === '0xcd97f8d1a604ccd06807e5b60fb0fda00bba5eab') {
    fail('roles.team is the vesting Team tranche Safe (HCOW-Team), not HCOW-TeamRev');
  }

  for (const k of ['owner', 'settler', 'gameCompany', 'team', 'funder']) {
    const a = roles[k];
    if (!a) continue;
    const code = await p.getCode(a);
    if (code === '0x') { fail(`${k} ${a} has no code: not a deployed Safe on this chain`); continue; }
    try {
      const s = new ethers.Contract(a, SAFE_ABI, p);
      const [t, owners] = await Promise.all([s.getThreshold(), s.getOwners()]);
      const want = new Set(signers.map((x) => x.toLowerCase()));
      const got = owners.map((x) => x.toLowerCase());
      const same = got.length === want.size && got.every((x) => want.has(x));
      if (Number(t) < cfg.safeMinThreshold) fail(`${k} Safe threshold is ${t}, expected >= ${cfg.safeMinThreshold}`);
      if (!same) fail(`${k} Safe owners are ${owners.join(', ')}, expected HW-A/B/C`);
      if (Number(t) >= cfg.safeMinThreshold && same) ok(`${k.padEnd(11)} ${a}  Safe ${t}-of-${owners.length}, HW-A/B/C`);
    } catch (e) {
      fail(`${k} ${a} has code but does not answer as a Safe: ${e.shortMessage || e.message}`);
    }
  }
  if (roles.anchorer) {
    const code = await p.getCode(roles.anchorer);
    if (code !== '0x') fail(`anchorer ${roles.anchorer} has code. It must be a plain hot wallet`);
    else ok(`anchorer    ${roles.anchorer}  plain wallet`);
  }

  // ---- tokens ------------------------------------------------------------
  log('\ntokens');
  const hcowA = addr('tokens.HCOW', cfg.tokens.HCOW);
  const usdtA = addr('tokens.USDT', cfg.tokens.USDT);
  if (usdtA !== BSC_USD) fail(`tokens.USDT is ${usdtA}, not BSC-USD ${BSC_USD}`);
  for (const [label, a, want] of [['HCOW', hcowA, { name: 'HashCow', symbol: 'HCOW', supply: SUPPLY }],
                                   ['USDT', usdtA, { symbol: 'USDT' }]]) {
    try {
      const t = new ethers.Contract(a, ERC20, p);
      const [n, s, d, ts] = await Promise.all([t.name(), t.symbol(), t.decimals(), t.totalSupply()]);
      const bad = (want.name && n !== want.name) || s !== want.symbol || Number(d) !== 18 ||
                  (want.supply && ts !== want.supply);
      if (bad) fail(`${label} ${a} answers "${n}" ${s} ${d} decimals supply ${fmt(ts)}`);
      else ok(`${label.padEnd(4)} ${a}  "${n}" ${s} 18 decimals${want.supply ? ' supply 200,000,000' : ''}`);
    } catch (e) {
      fail(`${label} ${a} does not answer as an ERC20: ${e.shortMessage || e.message}`);
    }
  }

  // ---- deploy key --------------------------------------------------------
  let predicted = null;
  if (me) {
    log('\ndeploy key');
    const [bal, nonce, fee] = await Promise.all([p.getBalance(me), p.getTransactionCount(me, 'pending'),
                                                  p.getFeeData()]);
    const gasPrice = fee.gasPrice ?? 0n;
    const need = (DEPLOY_GAS * gasPrice * 3n) / 2n;
    log(`  address  ${me}`);
    log(`  balance  ${ethers.formatEther(bal)} BNB   nonce ${nonce}   gas price ${ethers.formatUnits(gasPrice, 'gwei')} gwei`);
    log(`  needs    about ${ethers.formatEther(need)} BNB for the four deployments (+50% margin)`);
    if (bal < need) fail(`deploy key holds ${ethers.formatEther(bal)} BNB, needs about ${ethers.formatEther(need)}`);
    // Same order as deploy.cjs: Ledger, Staking, RewardVault, ProfitShare.
    predicted = {
      HCOWLedger: ethers.getCreateAddress({ from: me, nonce }),
      HCOWStaking: ethers.getCreateAddress({ from: me, nonce: nonce + 1 }),
      HCOWRewardVault: ethers.getCreateAddress({ from: me, nonce: nonce + 2 }),
      HCOWProfitShare: ethers.getCreateAddress({ from: me, nonce: nonce + 3 }),
    };
    log('  predicted addresses (valid only if nothing else is sent from this key first)');
    for (const [k, v] of Object.entries(predicted)) log(`    ${k.padEnd(16)} ${v}`);
  } else {
    warn('DEPLOYER_ADDRESS not given: deploy key balance and predicted addresses not checked');
  }

  // ---- reward budget (informational: needed after deployment) -----------
  log('\nreward budget');
  try {
    const inc = addr('incentivesSafe', cfg.incentivesSafe);
    const h = new ethers.Contract(hcowA, ERC20, p);
    const v = new ethers.Contract(addr('vesting', cfg.vesting), ['function releasable(address) view returns (uint256)'], p);
    const [held, rel] = await Promise.all([h.balanceOf(inc), v.releasable(inc)]);
    const want = ethers.parseUnits(cfg.rewards.firstAmountHcow, 18);
    log(`  Incentives Safe ${inc} holds ${fmt(held)} HCOW, ${fmt(rel)} more releasable from vesting`);
    if (held < want) {
      if (held + rel >= want) warn(`Incentives Safe needs a vesting release before the first ${cfg.rewards.firstAmountHcow} HCOW funding (anyone can call release)`);
      else warn(`Incentives Safe cannot cover the first ${cfg.rewards.firstAmountHcow} HCOW funding yet`);
    } else ok(`covers the first ${cfg.rewards.firstAmountHcow} HCOW funding`);
  } catch (e) {
    warn(`could not read the reward budget: ${e.shortMessage || e.message}`);
  }

  log(`\n${fails.length} failed, ${warns.length} warnings`);
  return { ok: fails.length === 0, fails, warns, roles, predicted, cfg, deployer: me };
}

module.exports = { preflight };

if (require.main === module) {
  let d = process.env.DEPLOYER_ADDRESS || null;
  if (!d && process.env.DEPLOYER_KEY) {
    // Never let a malformed key reach an error message (2026-09-28 incident).
    try { d = new ethers.Wallet(process.env.DEPLOYER_KEY).address; }
    catch { console.error(`DEPLOYER_KEY is not a valid private key (length ${process.env.DEPLOYER_KEY.length}; expected 64 or 66)`); process.exit(1); }
  }
  preflight({ deployer: d }).then((r) => { if (!r.ok) process.exitCode = 1; })
    .catch((e) => { console.error(e.shortMessage || e.message); process.exitCode = 1; });
}
