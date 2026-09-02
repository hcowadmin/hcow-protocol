'use strict';
// Testnet only. Puts gas and stand-in tokens into the role wallets so that a
// role-separated deployment can actually be exercised.
//
//   DEPLOYER_KEY=0x... npx hardhat run scripts/fundroles.cjs --network bscTestnet
//
// Why this exists. deploy.cjs with REHEARSAL=yes produces the shape mainnet
// requires: six roles, six different wallets, none of them the deploy key.
// That shape is also the shape in which nothing works until each wallet holds
// what its role spends. The anchorer needs gas. The settler needs gas and
// USDT. The funder needs gas and HCOW. Discovering that on mainnet, one
// reverted transaction at a time, is the outcome this script exists to move
// forward into the rehearsal.
//
// It reads deployments/<network>.json for the token addresses and takes each
// role address from the same environment variables deploy.cjs used, so a
// rehearsal cannot fund a different set of wallets than it deployed against.

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect, at, ethers } = require('./_connect.cjs');

const TESTNET = 97n;

// Gas floats. Deliberately small: these wallets are disposable and a testnet
// faucet is not infinite. topUp() only sends the difference, so re-running the
// script after a long smoke session costs almost nothing.
const GAS_TARGET = ethers.parseEther('0.01');

// Only the roles that SIGN need gas. gameCompany and team never send a
// transaction in this system: HCOWProfitShare pushes their legs to them during
// settlement. Funding them anyway is how a 0.3 tBNB faucet claim, which is one
// claim per address per 24 hours, turns into a two day wait for no reason.
const SIGNING_ROLES = ['owner', 'anchorer', 'settler', 'funder'];
const SETTLER_USDT = ethers.parseUnits('100000', 18);
const FUNDER_HCOW = ethers.parseUnits('1000000', 18);

async function main() {
  const { provider, signer } = connect();
  const net = await provider.getNetwork();
  if (net.chainId !== TESTNET) {
    throw new Error(
      `refusing to run on chain ${net.chainId}. This script hands out gas and ` +
      'tokens from the deploy key, which is a testnet-only idea.'
    );
  }

  const file = path.join(__dirname, '..', 'deployments', `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}, run deploy.cjs first`);
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));

  const me = await signer.getAddress();
  console.log(`network   ${hre.network.name} (chainId ${net.chainId})`);
  console.log(`funding from ${me}\n`);

  // The roles as recorded by the deployment, not as re-read from the
  // environment. An environment that has drifted since the deploy would fund
  // wallets that hold no role, leave the real ones empty, and produce a smoke
  // run that fails for a reason nobody would look for.
  const roles = d.roles;
  if (!roles) throw new Error('deployment record has no roles block; redeploy with the current script');

  const hcow = await at('MockHCOW', d.addresses.HCOW, signer);
  const usdt = await at('MockUSDT', d.addresses.USDT, signer);

  const topUp = async (label, address) => {
    if (!address || address.toLowerCase() === me.toLowerCase()) return;
    const bal = await provider.getBalance(address);
    if (bal >= GAS_TARGET) {
      console.log(`  ${label.padEnd(13)} ${address}  gas ok (${ethers.formatEther(bal)} BNB)`);
      return;
    }
    const send = GAS_TARGET - bal;
    const tx = await signer.sendTransaction({ to: address, value: send });
    await tx.wait();
    console.log(`  ${label.padEnd(13)} ${address}  +${ethers.formatEther(send)} BNB  tx ${tx.hash}`);
  };

  console.log('gas');
  for (const label of SIGNING_ROLES) await topUp(label, roles[label]);
  for (const label of Object.keys(roles)) {
    if (!SIGNING_ROLES.includes(label)) {
      console.log(`  ${label.padEnd(13)} ${roles[label]}  no gas needed, receives only`);
    }
  }

  const give = async (token, symbol, label, address, want) => {
    if (!address || address.toLowerCase() === me.toLowerCase()) return;
    const bal = await token.balanceOf(address);
    if (bal >= want) {
      console.log(`  ${label.padEnd(13)} ${address}  ${symbol} ok (${ethers.formatUnits(bal, 18)})`);
      return;
    }
    const send = want - bal;
    const tx = await token.transfer(address, send);
    await tx.wait();
    console.log(`  ${label.padEnd(13)} ${address}  +${ethers.formatUnits(send, 18)} ${symbol}  tx ${tx.hash}`);
  };

  console.log('\ntokens');
  await give(usdt, 'USDT', 'settler', roles.settler, SETTLER_USDT);
  await give(hcow, 'HCOW', 'funder', roles.funder, FUNDER_HCOW);

  console.log('\nThe tokens above are stand-ins and have no value.');
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
