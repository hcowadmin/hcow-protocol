'use strict';
// Testnet only. Puts stand-in tokens into HCOWFaucet so testers can actually
// bond and stake rather than only look at the UI.
//
//   DEPLOYER_KEY=0x... npx hardhat run scripts/fundfaucet.cjs --network bscTestnet
//   CLAIMS=250 DEPLOYER_KEY=0x... npx hardhat run scripts/fundfaucet.cjs --network bscTestnet
//
// The faucet has no mint path and no deposit function. It hands out what it
// holds, and a plain ERC20 transfer is how it comes to hold anything. That is
// deliberate: a faucet that could mint would be a faucet that could mint the
// real token if it were ever pointed at one.
//
// Per-claim amounts are read off the contract rather than assumed here. They
// are owner-settable, so a constant in this script would be a second source of
// truth that silently disagrees the moment anyone calls setAmounts.

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect, at, ethers } = require('./_connect.cjs');

const TESTNET = 97n;
const CLAIMS = BigInt(process.env.CLAIMS || '100');

async function main() {
  const { provider, signer } = connect();
  const net = await provider.getNetwork();
  if (net.chainId !== TESTNET) {
    throw new Error(
      `refusing to run on chain ${net.chainId}. A faucet giving away whatever ` +
      'is put into it is meaningless for stand-in tokens and unacceptable for ' +
      'real ones.');
  }

  const file = path.join(__dirname, '..', 'deployments', `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}, run deploy.cjs first`);
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!d.addresses.HCOWFaucet) throw new Error('this deployment has no faucet');

  const me = await signer.getAddress();
  const faucet = await at('HCOWFaucet', d.addresses.HCOWFaucet, signer);
  const hcow = await at('MockHCOW', d.addresses.HCOW, signer);
  const usdt = await at('MockUSDT', d.addresses.USDT, signer);

  const perHcow = await faucet.hcowAmount();
  const perUsdt = await faucet.usdtAmount();
  const fmt = (v) => ethers.formatUnits(v, 18);

  console.log(`network   ${hre.network.name} (chainId ${net.chainId})`);
  console.log(`faucet    ${d.addresses.HCOWFaucet}`);
  console.log(`per claim ${fmt(perHcow)} HCOW + ${fmt(perUsdt)} USDT`);
  console.log(`target    ${CLAIMS} claims\n`);

  const top = async (token, symbol, want) => {
    const held = await token.balanceOf(d.addresses.HCOWFaucet);
    if (held >= want) {
      console.log(`  ${symbol.padEnd(5)} already holds ${fmt(held)}, enough for ` +
                  `${held / (symbol === 'HCOW' ? perHcow : perUsdt)} claims`);
      return;
    }
    const send = want - held;
    const mine = await token.balanceOf(me);
    if (mine < send) {
      throw new Error(`deployer holds ${fmt(mine)} ${symbol} but needs ${fmt(send)}`);
    }
    const tx = await token.transfer(d.addresses.HCOWFaucet, send);
    await tx.wait();
    console.log(`  ${symbol.padEnd(5)} +${fmt(send)}  tx ${tx.hash}`);
  };

  await top(hcow, 'HCOW', perHcow * CLAIMS);
  await top(usdt, 'USDT', perUsdt * CLAIMS);

  const hBal = await hcow.balanceOf(d.addresses.HCOWFaucet);
  const uBal = await usdt.balanceOf(d.addresses.HCOWFaucet);
  const claimsLeft = (a, per) => (per === 0n ? 'n/a' : (a / per).toString());
  console.log(`\nfaucet now holds ${fmt(hBal)} HCOW and ${fmt(uBal)} USDT`);
  console.log(`that is ${claimsLeft(hBal, perHcow)} HCOW claims and ` +
              `${claimsLeft(uBal, perUsdt)} USDT claims`);
  console.log('\nOne claim per address per 24 hours, 250 claims per rolling window.');
  console.log('The faucet does not dispense gas and cannot: calling claim costs gas.');
  console.log('Testers need tBNB from the public faucet or from the team.');
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
