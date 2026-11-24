'use strict';
// Shared plumbing for the mainnet procedure (2026-11).
//
// Nothing in here signs anything. Every function reads the chain through a
// plain JsonRpcProvider. The only script that sends a transaction is
// deploy.cjs itself, reached through mainnet-deploy.cjs after these checks.
//
// Why a config file rather than exported environment variables. In September
// the roles were typed into a terminal one export at a time, and the record
// shows two near misses from it: an address pasted into the wrong variable
// and a key printed by an error message. Here every address lives in
// config/mainnet.json, is read by every script from the same place, and is
// checked against the chain before use.

const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

const ROOT = path.join(__dirname, '..');
// MAINNET_CONFIG exists for the local rehearsal only, which needs a stand-in
// anchorer while the real one is not chosen yet.
const CONFIG = process.env.MAINNET_CONFIG || path.join(ROOT, 'config', 'mainnet.json');
const BSC_USD = '0x55d398326f99059fF775485246999027B3197955';
const SUPPLY = 200_000_000n * 10n ** 18n;

function loadConfig() {
  const c = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  return c;
}

function isLocal() {
  return hre.network.name === 'localhost' || hre.network.name === 'hardhat';
}

function provider() {
  const cfg = hre.network.config;
  if (!cfg.url) throw new Error(`network "${hre.network.name}" has no RPC url`);
  return new ethers.JsonRpcProvider(cfg.url, undefined, { staticNetwork: true });
}

function recordPath() {
  return path.join(ROOT, 'deployments', `${hre.network.name}.json`);
}

function readRecord() {
  const f = recordPath();
  if (!fs.existsSync(f)) return null;
  return JSON.parse(fs.readFileSync(f, 'utf8'));
}

// Every address in the config, checksummed, or a precise error saying which.
function addr(label, v) {
  if (!v) throw new Error(`${label} is empty in config/mainnet.json`);
  if (!ethers.isAddress(v)) throw new Error(`${label} is not an address: ${v}`);
  const a = ethers.getAddress(v);
  // A mixed-case string that does not match its own checksum is a typo that
  // ethers would silently "correct". Refuse it instead.
  const body = v.slice(2);
  const mixed = body !== body.toLowerCase() && body !== body.toUpperCase();
  if (mixed && v !== a) {
    throw new Error(`${label} has a bad EIP-55 checksum: ${v}`);
  }
  return a;
}

const SAFE_ABI = [
  'function getThreshold() view returns (uint256)',
  'function getOwners() view returns (address[])',
];
const ERC20 = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
];

const fmt = (wei) => ethers.formatUnits(wei, 18);

module.exports = {
  hre, fs, path, ethers, ROOT, BSC_USD, SUPPLY, SAFE_ABI, ERC20,
  loadConfig, isLocal, provider, recordPath, readRecord, addr, fmt,
};
