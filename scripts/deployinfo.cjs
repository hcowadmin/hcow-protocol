'use strict';
// Prints the exact configuration values the dApp build and the event indexer
// need, read off the chain rather than transcribed by hand.
//
//   npx hardhat run scripts/deployinfo.cjs --network bscTestnet
//
// For a deployment made before deploy.cjs started recording transaction
// hashes, pass the FIRST deployment transaction from that run:
//
//   DEPLOY_TX=0x... npx hardhat run scripts/deployinfo.cjs --network bscTestnet
//
// Why this exists. After a redeploy, three things elsewhere still point at the
// previous contracts: the dApp bundle, the indexer's watched addresses, and the
// indexer's GENESIS_BLOCK. The first two are addresses anyone can copy from the
// deployment record. The third is a block number that exists nowhere except the
// chain, and getting it wrong is quiet in both directions: too high and the
// indexer silently skips everything before it, too low and it spends days of
// scheduled runs walking blocks that contain nothing.
//
// It is derived from a transaction receipt rather than by scanning. An earlier
// version of this script walked logs backwards to find the first one, which is
// correct and does not work: public BSC endpoints cap eth_getLogs by block
// range and answer a wide one with "limit exceeded" rather than a partial
// result. eth_getTransactionReceipt has no such cap, needs no archive node,
// and costs one call.

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect } = require('./_connect.cjs');

async function main() {
  const { provider } = connect();
  const net = await provider.getNetwork();
  const head = await provider.getBlockNumber();

  const file = path.join(__dirname, '..', 'deployments', `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}`);
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  const a = d.addresses;

  console.log(`network ${hre.network.name} (chainId ${net.chainId})  head ${head}\n`);

  // Where the deployment blocks come from, in order of preference.
  const blocks = {};
  let source;

  if (d.deploymentBlocks && Object.keys(d.deploymentBlocks).length) {
    Object.assign(blocks, d.deploymentBlocks);
    source = 'the deployment record';
  } else {
    const hashes = Object.entries(d.deploymentTxs || {});
    if (process.env.DEPLOY_TX) hashes.push(['DEPLOY_TX', process.env.DEPLOY_TX]);
    if (!hashes.length) {
      throw new Error(
        'This deployment record predates transaction-hash recording, so the\n' +
        'deployment block cannot be derived from it. Re-run with the FIRST\n' +
        'deployment transaction of that run, which is the line printed for\n' +
        'MockHCOW (testnet) or the first contract (mainnet):\n\n' +
        '  DEPLOY_TX=0x... npx hardhat run scripts/deployinfo.cjs --network ' +
        hre.network.name);
    }
    for (const [name, hash] of hashes) {
      const r = await provider.getTransactionReceipt(hash);
      if (!r) throw new Error(`no receipt for ${name} tx ${hash}. Wrong network?`);
      blocks[name] = r.blockNumber;
    }
    source = 'transaction receipts';
  }

  console.log(`deployment blocks, from ${source}:`);
  for (const [name, b] of Object.entries(blocks)) console.log(`  ${name.padEnd(16)} ${b}`);

  // Inclusive from-block, so one below the earliest. A single extra block
  // costs nothing; being one short loses the constructor events silently.
  const earliest = Math.min(...Object.values(blocks));
  const genesis = earliest - 1;

  const bar = '-'.repeat(72);
  console.log(`\n${bar}\nSUPABASE EDGE FUNCTION SECRETS  (function swift-task)\n${bar}`);
  console.log(`CHAIN_ID=${net.chainId}`);
  console.log(`GENESIS_BLOCK=${genesis}`);
  console.log(`LEDGER_ADDRESS=${a.HCOWLedger}`);
  console.log(`PROFIT_SHARE_ADDRESS=${a.HCOWProfitShare}`);
  console.log(`STAKING_ADDRESS=${a.HCOWStaking}`);

  console.log(`\n${bar}\nDAPP BUILD ENVIRONMENT  (only if not using the committed defaults)\n${bar}`);
  console.log(`VITE_CHAIN_ID=${net.chainId}`);
  console.log(`VITE_HCOW_ADDRESS=${a.HCOW}`);
  console.log(`VITE_USDT_ADDRESS=${a.USDT}`);
  console.log(`VITE_PROFIT_SHARE_ADDRESS=${a.HCOWProfitShare}`);
  console.log(`VITE_STAKING_ADDRESS=${a.HCOWStaking}`);
  console.log(`VITE_LEDGER_ADDRESS=${a.HCOWLedger}`);
  if (a.HCOWFaucet) console.log(`VITE_FAUCET_ADDRESS=${a.HCOWFaucet}`);

  const b0 = await provider.getBlock(earliest);
  if (b0) console.log(`VITE_GENESIS_MS=${b0.timestamp * 1000}`);

  console.log(`\n${bar}`);
  console.log('The indexer keys its cursor by chain id and address, so the new');
  console.log('contracts start clean and nothing has to be deleted. Rows from the');
  console.log('previous deployment stay where they are, under the old addresses,');
  console.log('and are never read again.');
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
