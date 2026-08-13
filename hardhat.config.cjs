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
