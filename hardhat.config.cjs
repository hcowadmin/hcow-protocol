const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");

// The sandbox cannot reach binaries.soliditylang.org, so use the solc that
// npm already installed. Same compiler, just resolved locally.
//
// 0.8.34 is the version Remix ships as its bundled local compiler, and Remix
// only offers that one when it cannot reach the version list either. Building
// and testing on the same version the contracts are actually deployed with is
// worth more than pinning to an older one nobody can run.
const LOCAL_SOLC = { "0.8.34": "solc-0834", "0.8.26": "solc" };

subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async (args, hre, runSuper) => {
  const pkg = LOCAL_SOLC[args.solcVersion];
  if (pkg) {
    return {
      compilerPath: require.resolve(`${pkg}/soljson.js`),
      isSolcJs: true,
      version: args.solcVersion,
      longVersion: require(pkg).version(),
    };
  }
  return runSuper();
});

// Deploy keys come from the environment and are never committed.
// DEPLOYER_KEY is a throwaway key for testnet only. Mainnet deployment
// signs from a hardware wallet through Remix, not from here.
const key = process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [];

// evmVersion is pinned to "paris" DELIBERATELY, and it must not be changed
// without changing it in every other place it appears.
//
// Why paris and not shanghai/cancun. The difference that matters is PUSH0
// (shanghai) and transient storage plus MCOPY (cancun). BNB Chain has
// supported all of them since the Feynman/Pascal upgrades, so the choice is
// gas, not capability: paris costs a small amount more on constant pushes and
// nothing else here, because no contract in this repository uses transient
// storage or memory copying in a hot loop. What paris buys is that the
// bytecode contains no opcode that a BSC-compatible chain, an archive node, a
// tracing tool or a fork used by an auditor might not implement. For a set of
// contracts whose whole security argument is that anyone can re-derive and
// re-verify them, that is worth more than the gas.
//
// Why it must match everywhere. The compiler settings are part of the
// verification input on BscScan. Source that compiles to identical bytecode
// under paris and different bytecode under cancun will fail verification with
// no useful error, and a contract that cannot be verified cannot be audited by
// a reader. The same three settings, 0.8.34 / optimizer 200 / paris, appear
// here, in this repository's foundry.toml, and in the hcow-contracts
// repository's foundry.toml and compile.cjs. scripts/checkflat.cjs is what
// notices if the flattened sources and the artifacts drift apart.
module.exports = {
  solidity: {
    version: "0.8.34",
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "paris" },
  },
  networks: {
    // HARDHAT_CHAIN_ID lets a local node impersonate chain 97 so the deploy
    // and smoke scripts can be rehearsed end to end before spending real
    // testnet BNB. Nothing in the contracts depends on the chain id.
    hardhat: { chainId: Number(process.env.HARDHAT_CHAIN_ID || 31337) },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: Number(process.env.HARDHAT_CHAIN_ID || 31337),
    },
    bscTestnet: {
      url: process.env.BSC_TESTNET_RPC || "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
      chainId: 97,
      accounts: key,
    },
    bsc: {
      url: process.env.BSC_RPC || "https://bsc-dataseed.bnbchain.org",
      chainId: 56,
      accounts: key,
    },
  },
};
