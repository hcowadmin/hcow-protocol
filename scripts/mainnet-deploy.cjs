'use strict';
// The mainnet deployment, as one command.
//
//   read -s DEPLOYER_KEY          (its own line; paste the key; Enter)
//   export DEPLOYER_KEY
//   CONFIRM=DEPLOY npx hardhat run scripts/mainnet-deploy.cjs --network bsc
//   unset DEPLOYER_KEY
//
// What it does, in order:
//   1. checks the key is well formed WITHOUT ever printing it
//   2. runs every mainnet-preflight.cjs check; any failure stops here and
//      nothing is sent
//   3. exports the six role addresses from config/mainnet.json, so none of
//      them is typed by hand
//   4. runs deploy.cjs, unmodified (the audited file), which deploys
//      HCOWLedger, HCOWStaking, HCOWRewardVault, HCOWProfitShare, writes
//      deployments/bsc.json and reads the wiring back from the chain
//   5. compares what landed with the addresses predicted in step 2
//
// Without CONFIRM=DEPLOY it stops after step 2. That is the dry run.

const { ethers, loadConfig } = require('./_mainnet.cjs');
const { preflight } = require('./mainnet-preflight.cjs');

async function main() {
  const key = process.env.DEPLOYER_KEY;
  if (!key) throw new Error('DEPLOYER_KEY is not set. Use read -s on its own line, then export DEPLOYER_KEY.');
  let deployer;
  try { deployer = new ethers.Wallet(key).address; }
  catch { throw new Error(`DEPLOYER_KEY is not a valid private key (length ${key.length}; expected 64 or 66). Nothing was sent.`); }

  const r = await preflight({ deployer });
  if (!r.ok) throw new Error('preflight failed, nothing was sent');

  const cfg = loadConfig();
  process.env.HCOW_ADDRESS = cfg.tokens.HCOW;
  process.env.USDT_ADDRESS = cfg.tokens.USDT;
  process.env.OWNER_ADDRESS = r.roles.owner;
  process.env.ANCHORER_ADDRESS = r.roles.anchorer;
  process.env.SETTLER_ADDRESS = r.roles.settler;
  process.env.GAME_COMPANY_ADDRESS = r.roles.gameCompany;
  process.env.TEAM_ADDRESS = r.roles.team;
  process.env.FUNDER_ADDRESS = r.roles.funder;
  delete process.env.ALLOW_SHARED_ROLES;
  delete process.env.REHEARSAL;

  if (process.env.CONFIRM !== 'DEPLOY') {
    console.log('\nDry run only. Re-run with CONFIRM=DEPLOY to deploy the four contracts.');
    return;
  }

  console.log('\n==== deploy.cjs ====\n');
  // Run the audited script as its own process, exactly as it would be run by
  // hand, and wait for its exit code.
  const { spawnSync } = require('child_process');
  const hre = require('hardhat');
  const fs = require('fs');
  const { recordPath } = require('./_mainnet.cjs');
  const res = spawnSync('npx', ['hardhat', 'run', 'scripts/deploy.cjs', '--network', hre.network.name],
    { stdio: 'inherit', env: process.env, cwd: require('path').join(__dirname, '..') });
  if (res.status !== 0) {
    throw new Error(fs.existsSync(recordPath())
      ? 'deploy.cjs reported a failure AFTER writing a record. Contracts may exist on chain. Do not re-run it; send the screen to Claude.'
      : 'deploy.cjs failed before writing a record (see above).');
  }

  const rec = JSON.parse(fs.readFileSync(recordPath(), 'utf8'));
  console.log('\nlanded vs predicted');
  let same = true;
  for (const [k, v] of Object.entries(r.predicted)) {
    const got = rec.addresses[k];
    const okk = got && got.toLowerCase() === v.toLowerCase();
    same = same && okk;
    console.log(`  ${okk ? 'ok ' : 'DIFF'} ${k.padEnd(16)} ${got}`);
  }
  if (!same) console.log('  (a difference means another transaction was sent from this key in between. The record is what counts.)');
  console.log('\nNext: unset DEPLOYER_KEY, then run scripts/mainnet-postdeploy.cjs');
}

main().catch((e) => { console.error(e.shortMessage || e.message); process.exitCode = 1; });
