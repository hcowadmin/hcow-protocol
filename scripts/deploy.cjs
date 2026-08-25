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

  // Off testnet every role must be named explicitly and must not be the key
  // running this script. Defaulting to the deployer is convenient on a test
  // chain and a total loss of every economic control on mainnet: one forgotten
  // export and one hot key owns the settler, both revenue recipients, the
  // reward funder and the anchorer, with the deployment recorded as canonical.
  const mainnet = net.chainId !== TESTNET;
  const role = (k) => {
    if (!mainnet) return env(k, me);
    const v = process.env[k];
    if (!v) throw new Error(`${k} must be set explicitly off testnet`);
    const a = env(k, null);
    if (a.toLowerCase() === me.toLowerCase()) {
      throw new Error(`${k} must not be the deploy key`);
    }
    if (a === ethers.ZeroAddress) throw new Error(`${k} must not be the zero address`);
    return a;
  };

  const owner = role('OWNER_ADDRESS');
  const anchorer = role('ANCHORER_ADDRESS');
  const settler = role('SETTLER_ADDRESS');
  const gameCompany = role('GAME_COMPANY_ADDRESS');
  const team = role('TEAM_ADDRESS');
  const funder = role('FUNDER_ADDRESS');

  // The settler funds every distribution out of its own balance. If it also
  // receives one of the fixed legs, the cost of publishing a revenue figure
  // drops by half, and to nothing when no participant is eligible.
  if (settler === gameCompany || settler === team) {
    throw new Error('SETTLER_ADDRESS must differ from GAME_COMPANY_ADDRESS and TEAM_ADDRESS');
  }

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

  // Both token addresses are immutable in HCOWProfitShare and HCOWStaking.
  // A wrong one is not a mistake that can be corrected: it is two permanently
  // wrong contracts and a redeploy. Ask the addresses what they are before
  // committing them, rather than checking that they look like addresses.
  //
  // Decimals in particular are load bearing and silent when wrong.
  // MIN_PARTICIPANT_USDT is 1e18, "one USDT" on BSC where USDT has eighteen
  // decimals. Against a six decimal USDT the same constant is a trillion
  // USDT, Rule 6 can never be satisfied, and the deduction mechanism is
  // disabled for the life of the contract with no error anywhere.
  const ERC20_META = [
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function totalSupply() view returns (uint256)',
  ];
  const describe = async (label, addr, expect) => {
    if ((await provider.getCode(addr)) === '0x') {
      throw new Error(`${label} ${addr} has no code on chain ${net.chainId}`);
    }
    const t = new ethers.Contract(addr, ERC20_META, provider);
    let name, symbol, decimals, supply;
    try {
      [name, symbol, decimals, supply] = await Promise.all([
        t.name(), t.symbol(), t.decimals(), t.totalSupply(),
      ]);
    } catch (e) {
      throw new Error(`${label} ${addr} does not answer as an ERC20: ${e.message}`);
    }
    console.log(`${label.padEnd(16)} ${addr}  ${symbol} "${name}" ${decimals} decimals, ` +
                `supply ${ethers.formatUnits(supply, decimals)}`);
    if (Number(decimals) !== 18) {
      throw new Error(
        `${label} has ${decimals} decimals. Both economic contracts assume 18: ` +
        'MIN_PARTICIPANT_USDT and MIN_STAKE_FOR_ACCRUAL are written as 1e18. ' +
        'Deploying against this token silently disables the deduction gate.'
      );
    }
    if (mainnet && expect && symbol.toUpperCase() !== expect) {
      throw new Error(`${label} reports symbol ${symbol}, expected ${expect}`);
    }
    return { symbol, decimals: Number(decimals), supply: supply.toString() };
  };

  console.log('');
  const hcowMeta = await describe('HCOW token', hcow, mainnet ? 'HCOW' : null);
  const usdtMeta = await describe('USDT token', usdt, null);
  if (hcow.toLowerCase() === usdt.toLowerCase()) {
    throw new Error('HCOW_ADDRESS and USDT_ADDRESS are the same address');
  }
  console.log('');

  // ---- contracts -------------------------------------------------------
  const ledger = await put('HCOWLedger', [owner, anchorer]);
  const profitShare = await put('HCOWProfitShare', [hcow, usdt, owner, settler, gameCompany, team]);
  const staking = await put('HCOWStaking', [hcow, owner, funder]);
  // Testnet only, and deliberately so. The faucet gives away whatever is put
  // into it, which is meaningless for stand in tokens and unacceptable for
  // real ones. It was previously deployed by hand and recorded nowhere.
  const faucet = net.chainId === TESTNET
    ? await put('HCOWFaucet', [hcow, usdt, owner])
    : null;

  // ---- record ----------------------------------------------------------
  const out = {
    network: hre.network.name,
    chainId: Number(net.chainId),
    deployedBy: me,
    roles: { owner, anchorer, settler, gameCompany, team, funder },
    tokens: { HCOW: hcowMeta, USDT: usdtMeta },
    addresses: Object.assign(
      { HCOW: hcow, USDT: usdt, HCOWLedger: ledger, HCOWProfitShare: profitShare, HCOWStaking: staking },
      faucet ? { HCOWFaucet: faucet } : {},
    ),
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
