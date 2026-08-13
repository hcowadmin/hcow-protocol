'use strict';
// Deploys the full HCOW contract set.
//
//   DEPLOYER_KEY=0x... npx hardhat run scripts/deploy.cjs --network bscTestnet
//
// On testnet it also deploys stand-in HCOW and USDT tokens, because the real
// HCOW token does not exist yet and BSC-USD is not on testnet. On any other
// network it refuses to invent tokens and requires real addresses:
//
//   HCOW_ADDRESS=0x... USDT_ADDRESS=0x... npx hardhat run scripts/deploy.cjs --network bsc
//
// Roles default to the deployer so a testnet run needs no configuration.
// For mainnet every one of these must be set deliberately:
//
//   OWNER_ADDRESS          hardware wallet or multisig. can never rewrite history
//   ANCHORER_ADDRESS       hot wallet the hourly worker signs with. gas only
//   SETTLER_ADDRESS        wallet that funds and settles an epoch. holds USDT
//   GAME_COMPANY_ADDRESS   receives 25%
//   TEAM_ADDRESS           receives 25%
//   FUNDER_ADDRESS         wallet that funds staking rewards in HCOW

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect, deploy, ethers } = require('./_connect.cjs');

const TESTNET = 97n;

async function main() {
  const { provider, signer } = connect();
  const net = await provider.getNetwork();
  const me = await signer.getAddress();
  const bal = await provider.getBalance(me);

  console.log(`network   ${hre.network.name} (chainId ${net.chainId})`);
  console.log(`deployer  ${me}`);
  console.log(`balance   ${ethers.formatEther(bal)} BNB\n`);
  if (bal === 0n) throw new Error('deployer has no BNB, nothing can be deployed');

  const env = (k, fallback) => {
    const v = process.env[k];
    if (!v) return fallback;
    if (!ethers.isAddress(v)) throw new Error(`${k} is not an address: ${v}`);
    return ethers.getAddress(v);
  };

  const owner = env('OWNER_ADDRESS', me);
  const anchorer = env('ANCHORER_ADDRESS', me);
  const settler = env('SETTLER_ADDRESS', me);
  const gameCompany = env('GAME_COMPANY_ADDRESS', me);
  const team = env('TEAM_ADDRESS', me);
  const funder = env('FUNDER_ADDRESS', me);

  const put = async (name, args) => {
    const c = await deploy(name, signer, args);
    const address = await c.getAddress();
    console.log(`${name.padEnd(16)} ${address}  tx ${c.deploymentTransaction().hash}`);
    return address;
  };

  // ---- tokens ----------------------------------------------------------
  let hcow = process.env.HCOW_ADDRESS;
  let usdt = process.env.USDT_ADDRESS;

  if (net.chainId === TESTNET) {
    if (!hcow) hcow = await put('MockHCOW', []);
    if (!usdt) usdt = await put('MockUSDT', []);
  }
  if (!hcow || !usdt) {
    throw new Error(
      'HCOW_ADDRESS and USDT_ADDRESS are required outside testnet. ' +
      'This script will not deploy placeholder tokens on a live network.'
    );
  }
  hcow = ethers.getAddress(hcow);
  usdt = ethers.getAddress(usdt);

  // ---- contracts -------------------------------------------------------
  const ledger = await put('HCOWLedger', [owner, anchorer]);
  const profitShare = await put('HCOWProfitShare', [hcow, usdt, owner, settler, gameCompany, team]);
  const staking = await put('HCOWStaking', [hcow, owner, funder]);

  // ---- record ----------------------------------------------------------
  const out = {
    network: hre.network.name,
    chainId: Number(net.chainId),
    deployedBy: me,
    roles: { owner, anchorer, settler, gameCompany, team, funder },
    addresses: { HCOW: hcow, USDT: usdt, HCOWLedger: ledger, HCOWProfitShare: profitShare, HCOWStaking: staking },
  };

  const dir = path.join(__dirname, '..', 'deployments');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${hre.network.name}.json`);
  fs.writeFileSync(file, JSON.stringify(out, null, 2) + '\n');

  console.log('\n' + JSON.stringify(out.addresses, null, 2));
  console.log(`\nwritten to ${file}`);

  if (net.chainId === TESTNET) {
    console.log('\nThe test tokens above are not HCOW and have no value.');
  }
  if (owner === me) {
    console.log(
      '\nWARNING: owner is the deploy key. Acceptable on testnet only. ' +
      'On mainnet the owner must be a hardware wallet or multisig.'
    );
  }
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
