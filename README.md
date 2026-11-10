# BlockFund

A crypto crowdfunding platform. A `BlockFund` factory contract deploys one contract per campaign. Donors give ETH or ERC-20 tokens, the owner collects once the goal is reached, and if the owner aborts, donors withdraw their own refunds.

> **Status: experimental.** `MixedCampaign` has known bugs (wrong-asset refunds, inverted price conversion, manipulable spot price). Don't deploy it to mainnet.

## Contracts

| Contract | What it does |
|---|---|
| `src/BlockFund.sol` | Factory. Creates campaigns and keeps the owner-managed token → Uniswap v4 pool registry used by mixed campaigns |
| `src/SimpleCampaign.sol` | ETH-only campaign |
| `src/TokenCampaign.sol` | Single ERC-20 campaign (donors `approve` first, then `donate`) |
| `src/MixedCampaign.sol` | ETH + one ERC-20, valued in ETH using a Uniswap v4 pool price |

## Setup

Install Foundry: https://getfoundry.sh

```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Clone with submodules (dependencies live in `lib/`):

```sh
git clone --recurse-submodules https://github.com/Yalhash/BlockFund
cd BlockFund
# already cloned without them?
git submodule update --init --recursive
```

Dependencies (pinned git submodules):

- `lib/forge-std` (v1.17.0): testing and scripting helpers
- `lib/openzeppelin-contracts` (v5.7.0): `IERC20`, `ERC20` mock
- `lib/v4-core` (v4.0.0): Uniswap v4 `IPoolManager`, `StateLibrary`, types

## Build and test

```sh
forge build
forge test            # add -vvv for traces
forge test --match-contract TokenCampaignTest
forge coverage
```

CI runs `forge build` and `forge test` on every push (`.github/workflows/test.yml`).

## Deploy

Copy `.env.example` to `.env`, fill it in, then `source .env`.

Local chain:

```sh
anvil                         # in another terminal
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 POOL_MANAGER=0x0000000000000000000000000000000000000001 \
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
```

(That's anvil's first default account. Simple and Token campaigns work locally. Mixed campaigns need a real v4 pool, so run `anvil --fork-url $SEPOLIA_RPC_URL` and use the real PoolManager address.)

Testnet: import your key once with `cast wallet import deployer --interactive`, then:

```sh
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast
```

## Version history

Each earlier version has its own branch with a README describing that stage:

- `V1.0.0`: single contract, ETH-only campaigns
- `V2.0.0`: factory + one contract per campaign, abort and pull-based refunds
- `V3.0.0`: single-token ERC-20 campaigns
- `main`: mixed ETH/token campaigns via Uniswap v4 (in progress), Foundry tooling
