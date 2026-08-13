'use strict';
// Shared plumbing for the deploy and smoke scripts.
//
// This project has no hardhat-ethers plugin, on purpose: the test suites talk
// to the node directly so that `from` is always explicit. These scripts do the
// same. A JsonRpcProvider plus a Wallet sets `from` on every call, which is the
// behaviour money-moving contracts need.

const hre = require('hardhat');
const { ethers } = require('ethers');

function connect() {
  const cfg = hre.network.config;
  if (!cfg.url) {
    throw new Error(
      `network "${hre.network.name}" has no RPC url. ` +
      `Use --network bscTestnet, or --network localhost against a running node.`
    );
  }
  const provider = new ethers.JsonRpcProvider(cfg.url, undefined, { staticNetwork: true });

  const key = process.env.DEPLOYER_KEY ||
    (Array.isArray(cfg.accounts) && typeof cfg.accounts[0] === 'string' ? cfg.accounts[0] : null);
  if (!key) {
    throw new Error(
      'DEPLOYER_KEY is not set. Export the private key of a throwaway deploy ' +
      'wallet. Never use a key that holds treasury funds.'
    );
  }
  // NonceManager, not a bare Wallet. These scripts fire many transactions in
  // sequence and the provider caches eth_getTransactionCount for a polling
  // interval, which is long enough to reuse a nonce and abort a deployment
  // halfway through.
  const signer = new ethers.NonceManager(new ethers.Wallet(key, provider));
  return { provider, signer, ethers };
}

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function at(name, address, signer) {
  const art = await hre.artifacts.readArtifact(name);
  return new ethers.Contract(address, art.abi, signer);
}

module.exports = { connect, deploy, at, ethers };
