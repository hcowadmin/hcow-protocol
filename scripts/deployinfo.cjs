'use strict';
// Prints the exact configuration values the dApp build and the event indexer
// need, read off the chain rather than transcribed by hand.
//
//   npx hardhat run scripts/deployinfo.cjs --network bscTestnet
//
// Why this exists. After a redeploy, three things elsewhere are still pointing
// at the previous contracts: the dApp bundle, the indexer's watched addresses,
// and the indexer's GENESIS_BLOCK. The first two are addresses anyone can copy
// from the deployment record. The third is a block number that exists nowhere
// except the chain, and getting it wrong is quiet in both directions: too high
// and the indexer silently skips the events before it, too low and it spends
// days of scheduled runs walking blocks that contain nothing.
//
// The deployment block is found from the contract's own logs rather than with
// eth_getCode at a historical height, which needs an archive node that public
// BSC endpoints are not. Every contract here inherits Ownable, which emits
// OwnershipTransferred from its constructor, so the deployment block is the
// block of the earliest log the address has.

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect } = require('./_connect.cjs');

// Ten days of BSC blocks, which is about 28,800 a day. Deep enough for a
// redeploy anyone is still thinking about, shallow enough that a wrong answer
// is a "not found" rather than a twenty minute scan.
const MAX_LOOKBACK = 300_000;
const CHUNK = 5_000;

async function firstLogBlock(provider, address, head) {
  // Backwards in chunks: the answer is almost always in the first one or two,
  // because this is run right after a deployment.
  for (let hi = head; hi > head - MAX_LOOKBACK && hi > 0; hi -= CHUNK) {
    const lo = Math.max(0, hi - CHUNK + 1);
    let logs;
    try {
      logs = await provider.getLogs({ address, fromBlock: lo, toBlock: hi });
    } catch (e) {
      throw new Error(
        `eth_getLogs ${lo}-${hi} failed for ${address}: ${e.message}. ` +
        'Try a different BSC_TESTNET_RPC.');
    }
    if (logs.length) {
      // Keep going down while the previous chunk still has logs, so a contract
      // that was busy across a chunk boundary does not report the boundary as
      // its birth.
      let earliest = Math.min(...logs.map((l) => l.blockNumber));
      let cursor = lo;
      while (cursor > 0) {
        const nlo = Math.max(0, cursor - CHUNK);
        const prev = await provider.getLogs({ address, fromBlock: nlo, toBlock: cursor - 1 });
        if (!prev.length) break;
        earliest = Math.min(earliest, ...prev.map((l) => l.blockNumber));
        cursor = nlo;
      }
      return earliest;
    }
  }
  return null;
}

async function main() {
  const { provider } = connect();
  const net = await provider.getNetwork();
  const head = await provider.getBlockNumber();

  const file = path.join(__dirname, '..', 'deployments', `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}`);
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  const a = d.addresses;

  console.log(`network ${hre.network.name} (chainId ${net.chainId})  head ${head}\n`);
  console.log('finding deployment blocks from contract logs, this takes a moment');

  const watched = { HCOWLedger: a.HCOWLedger, HCOWProfitShare: a.HCOWProfitShare, HCOWStaking: a.HCOWStaking };
  const blocks = {};
  for (const [name, addr] of Object.entries(watched)) {
    const b = await firstLogBlock(provider, addr, head);
    blocks[name] = b;
    console.log(`  ${name.padEnd(16)} ${addr}  block ${b === null ? 'NOT FOUND' : b}`);
  }

  const found = Object.values(blocks).filter((b) => b !== null);
  if (!found.length) {
    throw new Error('no logs found for any contract. Wrong network, or the deployment is older than the lookback window.');
  }
  // One block below the earliest, because a from-block is inclusive and there
  // is no cost to a single extra block and a real cost to being one short.
  const genesis = Math.min(...found) - 1;

  const bar = '-'.repeat(72);
  console.log(`\n${bar}\nSUPABASE EDGE FUNCTION SECRETS (project nkmsgvgwleyaognxqfnb, function swift-task)\n${bar}`);
  console.log(`CHAIN_ID=${net.chainId}`);
  console.log(`GENESIS_BLOCK=${genesis}`);
  console.log(`LEDGER_ADDRESS=${a.HCOWLedger}`);
  console.log(`PROFIT_SHARE_ADDRESS=${a.HCOWProfitShare}`);
  console.log(`STAKING_ADDRESS=${a.HCOWStaking}`);

  console.log(`\n${bar}\nDAPP BUILD ENVIRONMENT (only needed if not using the committed defaults)\n${bar}`);
  console.log(`VITE_CHAIN_ID=${net.chainId}`);
  console.log(`VITE_HCOW_ADDRESS=${a.HCOW}`);
  console.log(`VITE_USDT_ADDRESS=${a.USDT}`);
  console.log(`VITE_PROFIT_SHARE_ADDRESS=${a.HCOWProfitShare}`);
  console.log(`VITE_STAKING_ADDRESS=${a.HCOWStaking}`);
  console.log(`VITE_LEDGER_ADDRESS=${a.HCOWLedger}`);
  if (a.HCOWFaucet) console.log(`VITE_FAUCET_ADDRESS=${a.HCOWFaucet}`);

  // The dApp needs epoch 0's start only until the first settlement lands, but
  // a wrong value there shows a countdown that is visibly nonsense, which is
  // worse than a missing one.
  const b0 = await provider.getBlock(Math.min(...found));
  if (b0) console.log(`VITE_GENESIS_MS=${b0.timestamp * 1000}`);

  console.log(`\n${bar}`);
  console.log('The indexer keys its cursor by chainId and address, so the new');
  console.log('contracts start clean and nothing has to be deleted. The rows from');
  console.log('the previous deployment stay where they are, under the old');
  console.log('addresses, and are simply never read again.');
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
