'use strict';
// Local mainnet stand-in. Run against `npx hardhat node` started with
// HARDHAT_CHAIN_ID=56, so deploy.cjs applies every mainnet rule.
//
// Puts at the REAL mainnet addresses:
//   HCOW (0x794b…6f2D)   MockHCOW code + storage: "HashCow" HCOW, 200,000,000
//   BSC-USD (0x55d3…7955) MockUSDT code + storage
//   every Safe in config  MockSafe code answering threshold 2, owners HW-A/B/C
// and funds the Incentives Safe and the Settler Safe the way mainnet will be.
// Nothing here runs against a real network: it refuses any chain but a local
// node.
const hre = require('hardhat');
const { ethers } = require('ethers');
const { loadConfig } = require('../../scripts/_mainnet.cjs');

const url = hre.network.config.url;
const p = new ethers.JsonRpcProvider(url, undefined, { staticNetwork: true });
const rpc = (m, a) => p.send(m, a);

async function deployRaw(name, args, from) {
  const art = await hre.artifacts.readArtifact(name);
  const signer = await p.getSigner(from);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}
const slot = (n) => ethers.toBeHex(n, 32);
const mapSlot = (key, n) => ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['address', 'uint256'], [key, n]));

async function clone(src, dst, slots) {
  await rpc('hardhat_setCode', [dst, await p.getCode(src)]);
  for (const s of slots) await rpc('hardhat_setStorageAt', [dst, s, await p.getStorage(src, s)]);
}

async function main() {
  if (hre.network.name !== 'localhost') throw new Error('local node only');
  const cfg = loadConfig();
  const [admin, holder] = await p.listAccounts().then((a) => a.map((x) => x.address));

  const mh = await deployRaw('MockHCOW', [], admin);
  const mu = await deployRaw('MockUSDT', [], admin);
  // OpenZeppelin 5 ERC20 layout: 0 balances, 1 allowances, 2 totalSupply, 3 name, 4 symbol.
  await clone(await mh.getAddress(), cfg.tokens.HCOW, [slot(2), slot(3), slot(4)]);
  await clone(await mu.getAddress(), cfg.tokens.USDT, [slot(2), slot(3), slot(4)]);
  await rpc('hardhat_setStorageAt', [cfg.tokens.HCOW, mapSlot(holder, 0), slot(200_000_000n * 10n ** 18n)]);
  await rpc('hardhat_setStorageAt', [cfg.tokens.USDT, mapSlot(holder, 0), slot(100_000_000n * 10n ** 18n)]);

  const [a, b, c] = cfg.safeSigners;
  const ms = await deployRaw('MockSafe', [a, b, c, 2], admin);
  const safes = { ...cfg.roles, incentives: cfg.incentivesSafe };
  delete safes.anchorer;
  for (const [k, v] of Object.entries(safes)) {
    await rpc('hardhat_setCode', [v, await p.getCode(await ms.getAddress())]);
    await rpc('hardhat_setBalance', [v, '0x56BC75E2D63100000']); // 100 BNB for gas when impersonated
  }

  const hs = await p.getSigner(holder);
  const H = new ethers.Contract(cfg.tokens.HCOW, ['function transfer(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)'], hs);
  const U = new ethers.Contract(cfg.tokens.USDT, ['function transfer(address,uint256) returns (bool)'], hs);
  await (await H.transfer(cfg.incentivesSafe, ethers.parseUnits('20000', 18))).wait();
  await (await U.transfer(cfg.roles.settler, ethers.parseUnits('500', 18))).wait();
  console.log('local mainnet stand-in ready: tokens and Safes at their real addresses');
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
