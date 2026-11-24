#!/usr/bin/env bash
# Full local rehearsal of the mainnet procedure against a node that reports
# chainId 56, with HCOW, BSC-USD and every Safe at their real addresses.
# Uses the same scripts, unmodified, that the real run uses.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HARDHAT_CHAIN_ID=56
rm -f deployments/localhost.json; rm -rf out/mainnet
# real config; a stand-in anchorer (hardhat account 9) only if the config has none
node -e "const c=require('./config/mainnet.json');if(!c.roles.anchorer)c.roles.anchorer='0xa0Ee7A142d267C1f36714E4a8F75612F20a79720';require('fs').writeFileSync('/tmp/hcow-local-mainnet.json',JSON.stringify(c,null,2))"
export MAINNET_CONFIG=/tmp/hcow-local-mainnet.json
npx hardhat node > /tmp/hcow-node.log 2>&1 & NODE=$!
trap 'kill $NODE 2>/dev/null || true' EXIT
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:8545 && break; sleep 1; done
run() { npx hardhat run "$@" --network localhost; }
echo "== fixture";              run test/local-mainnet/fixture.cjs
# hardhat account 0: a key with no role, like the real deploy wallet
export DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
echo "== preflight";            DEPLOYER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 run scripts/mainnet-preflight.cjs
echo "== deploy (dry run)";     run scripts/mainnet-deploy.cjs
echo "== deploy";               CONFIRM=DEPLOY run scripts/mainnet-deploy.cjs
echo "== deploy again (must refuse)"; if CONFIRM=DEPLOY run scripts/mainnet-deploy.cjs; then echo "BAD: second deploy was not refused"; exit 1; else echo "  ok   refused"; fi
unset DEPLOYER_KEY
echo "== postdeploy";           run scripts/mainnet-postdeploy.cjs
for f in out/mainnet/safe/0*.json; do echo "== exec $(basename $f)"; BATCH=$f run test/local-mainnet/exec-batch.cjs; done
echo "== users stake and bond, one week passes"; STEP=before-settle run test/local-mainnet/scenario.cjs
echo "== settle batch (gross 11, direct 0.5, opex 0.5 -> profit 10 USDT, deduct 0)"
GROSS=11 DIRECT=0.5 OPEX=0.5 DEDUCT_PPM=0 run scripts/mainnet-settle-batch.cjs
BATCH=out/mainnet/safe/settle_epoch_1.json run test/local-mainnet/exec-batch.cjs
echo "== after settlement";     STEP=after-settle run test/local-mainnet/scenario.cjs
echo "REHEARSAL PASSED"
