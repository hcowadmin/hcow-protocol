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
// Roles default to the deployer so a first testnet run needs no configuration.
// Set REHEARSAL=yes on testnet to apply every mainnet role rule instead, which
// is how a testnet run becomes a rehearsal of the mainnet deployment rather
// than a functional smoke test:
//
//   REHEARSAL=yes OWNER_ADDRESS=0x... ANCHORER_ADDRESS=0x... \
//   SETTLER_ADDRESS=0x... GAME_COMPANY_ADDRESS=0x... TEAM_ADDRESS=0x... \
//   FUNDER_ADDRESS=0x... DEPLOYER_KEY=0x... \
//   npx hardhat run scripts/deploy.cjs --network bscTestnet
//
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
  // REHEARSAL=yes applies every mainnet role rule on testnet. The point of a
  // testnet run is not to see the contracts appear on an explorer, it is to
  // execute the mainnet procedure once where a mistake costs nothing. A run
  // where all six roles silently default to the deploy key rehearses nothing
  // and produces a deployment whose shape is exactly the one mainnet forbids.
  //
  // Everything about the ROLES is checked. Nothing about the TOKENS is: the
  // BSC-USD address pin and the HCOW symbol and supply checks stay on mainnet
  // only, because on testnet the tokens are stand-ins by design.
  const strict = mainnet || process.env.REHEARSAL === 'yes';
  const role = (k) => {
    if (!strict) return env(k, me);
    const v = process.env[k];
    if (!v) throw new Error(`${k} must be set explicitly (${mainnet ? 'off testnet' : 'REHEARSAL=yes'})`);
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

  // The rest of the separation, on mainnet only.
  //
  // Each role above was checked against the deploy key and against nothing
  // else, so five different wrong-but-plausible deployments passed every gate
  // in this script. They are not equivalent mistakes and none of them is
  // correctable: the contracts store these addresses immutably or behind
  // owner-only setters, and two of them govern a contract whose anchors can
  // never be rewritten.
  //
  //   OWNER == ANCHORER      the cold multisig has to co-sign every hourly
  //                          anchor, or the hot anchoring key owns the ledger.
  //                          The whole design assumes a gas-only anchorer.
  //   OWNER == SETTLER       the key that can rotate the settler IS the
  //                          settler, so the incident-response lever is held
  //                          by the thing it exists to remove.
  //   OWNER == FUNDER        same shape, one key for governance and operations.
  //   GAME_COMPANY == TEAM   allowed by the contract on purpose, but as a
  //                          deliberate choice rather than a typo, so it must
  //                          be stated.
  //
  // ALLOW_SHARED_ROLES is the deliberate-choice escape hatch and it is spelt
  // out in the error, so nobody has to guess whether the check is a bug.
  if (strict && process.env.ALLOW_SHARED_ROLES !== 'yes') {
    const pairs = [
      ['OWNER_ADDRESS', owner, 'ANCHORER_ADDRESS', anchorer],
      ['OWNER_ADDRESS', owner, 'SETTLER_ADDRESS', settler],
      ['OWNER_ADDRESS', owner, 'FUNDER_ADDRESS', funder],
      ['GAME_COMPANY_ADDRESS', gameCompany, 'TEAM_ADDRESS', team],
    ];
    for (const [an, a, bn, b] of pairs) {
      if (a.toLowerCase() === b.toLowerCase()) {
        throw new Error(
          `${an} and ${bn} are the same address (${a}). These roles are meant to ` +
          'be separately controlled and the contracts cannot be re-pointed after ' +
          'deployment. If this really is intended, set ALLOW_SHARED_ROLES=yes.'
        );
      }
    }
  }

  const put = async (name, args) => {
    const c = await deploy(name, signer, args);
    const address = await c.getAddress();
    console.log(`${name.padEnd(16)} ${address}  tx ${c.deploymentTransaction().hash}`);
    return address;
  };

  // BSC-USD (the token every explorer and wallet labels USDT) on BNB Chain
  // mainnet, 18 decimals, verified from the token's own BscScan page rather
  // than from a search result or an aggregator. Checked below on mainnet only.
  const BSC_USD_MAINNET = '0x55d398326f99059fF775485246999027B3197955';

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

  // On BNB Chain mainnet there is exactly one BSC-USD, and its address is
  // public and unchanging. Pin it.
  //
  // Every check above asks the address what it is, and a hostile or mistyped
  // token answers every one of them correctly: name "Tether USD", symbol
  // "USDT", 18 decimals, a plausible supply. Those checks catch a fat finger
  // that lands on some other real token. They do not catch a lookalike, and
  // the address is immutable in both economic contracts, so getting it wrong
  // is a redeploy of the whole estate rather than a correction.
  //
  // Deliberately a hard stop with no override. If BSC-USD is ever migrated,
  // changing this line is the right amount of friction for that decision.
  if (mainnet && usdt.toLowerCase() !== BSC_USD_MAINNET.toLowerCase()) {
    throw new Error(
      `USDT_ADDRESS is ${usdt}, which is not BSC-USD on BNB Chain mainnet. ` +
      `The only correct value is ${BSC_USD_MAINNET}. Both economic contracts ` +
      'store this address immutably, so a wrong one cannot be corrected later.'
    );
  }
  console.log('');

  // ---- contracts -------------------------------------------------------
  const ledger = await put('HCOWLedger', [owner, anchorer]);
  // The participant floor. Below this many bonded HCOW the pool is treated as
  // not yet real: the participant leg is scaled down against the floor and the
  // remainder is carried inside the contract until a real pool exists, rather
  // than being handed to the two fixed recipients. It is a deployment argument
  // rather than a compiled in constant because one number cannot describe "a
  // real pool" for every deployment, and the contract caps it at 5% of supply.
  // 1,000,000 HCOW is 0.5% of the 200,000,000 supply.
  const MIN_POOL_SHARES = 1_000_000n * 10n ** 18n;
  // Checked against the supply this script already read, rather than against
  // the comment above it. The contract caps the floor at 5% of supply, so a
  // token with a smaller supply than expected produces a MinPoolSharesTooHigh
  // revert in the middle of a deployment, and a token with a much larger one
  // produces a floor that describes nothing and no error anywhere.
  {
    const supply = BigInt(hcowMeta.supply);
    const cap = (supply * 500n) / 10_000n;
    if (MIN_POOL_SHARES > cap) {
      throw new Error(
        `MIN_POOL_SHARES ${MIN_POOL_SHARES} exceeds 5% of the HCOW supply ` +
        `(${supply}), which the contract caps at ${cap}`);
    }
    if (mainnet && supply !== 200_000_000n * 10n ** 18n) {
      throw new Error(
        `HCOW supply is ${supply}, not the 200,000,000e18 this deployment is ` +
        `sized for. Decide MIN_POOL_SHARES against the real supply before ` +
        `continuing.`);
    }
    console.log(`  minPoolShares      ${MIN_POOL_SHARES} ` +
                `(${(Number(MIN_POOL_SHARES * 10_000n / supply) / 100).toFixed(2)}% of supply, cap 5%)`);
  }
  const profitShare = await put('HCOWProfitShare',
    [hcow, usdt, owner, settler, gameCompany, team, MIN_POOL_SHARES]);
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
  if (!mainnet && process.env.REHEARSAL !== 'yes') {
    console.log(
      '\nNOTE: this run did not use REHEARSAL=yes, so the mainnet role rules ' +
      'were not applied. Treat it as a functional test, not as a rehearsal of ' +
      'the mainnet deployment.'
    );
  }
}

main().catch((e) => {
  console.error(e.message || e);
  process.exitCode = 1;
});
