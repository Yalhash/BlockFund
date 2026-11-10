# BlockFund

A crypto crowdfunding platform. A `BlockFund` factory contract deploys one contract per campaign. Campaigns are all-or-nothing with a deadline: if the goal is reached the owner collects, otherwise every donor withdraws their own donation.

> **Status: experimental, unaudited.** Don't deploy to mainnet with real funds.

## How a campaign works

1. Someone creates a campaign through `BlockFund` with an owner, a goal and a deadline (at most 365 days away).
2. Donors give until the deadline. Token donations need `token.approve(campaign, amount)` first.
3. **Goal reached:** the owner can call `settleCampaign()` at any time. After the deadline, *anyone* can, so funds never sit idle.
4. **Goal missed by the deadline, or the owner calls `abortCampaign()`:** refunds open. Each donor calls `withdrawDonation()` and gets back exactly what they gave, in the asset they gave.
5. The first settle or refund fixes the outcome (`state` becomes `Settled` or `Refunding`) and it never changes after that.

## Contracts

| Contract | What it does |
|---|---|
| `src/BlockFund.sol` | Factory. Creates campaigns; mixed campaigns are limited to tokens the oracle supports |
| `src/CampaignBase.sol` | Shared lifecycle: deadline, settle, abort, refunds, reentrancy guard |
| `src/SimpleCampaign.sol` | ETH only. Goal in wei |
| `src/TokenCampaign.sol` | One ERC-20. Goal in token base units |
| `src/MixedCampaign.sol` | ETH plus one ERC-20. Goal in wei; tokens valued by the oracle |
| `src/oracles/ChainlinkTwapOracle.sol` | Prices tokens in wei: Chainlink first, Uniswap v3 TWAP as a fallback |
| `src/interfaces/IPriceOracle.sol` | The interface campaigns use, so price sources can be swapped |

### Pricing (mixed campaigns)

Token donations are valued with sources that a flash loan can't move:

- **Chainlink** (primary): a TOKEN/ETH feed, or a TOKEN/USD feed converted through ETH/USD. A reading is rejected if it's older than the configured heartbeat, zero/negative, or the feed reverts.
- **Uniswap v3 TWAP** (fallback): average price over at least 30 minutes in a token/WETH pool, used when Chainlink is missing or unusable.
- WETH is valued 1:1. If neither source works, settling fails, and after the deadline donors can still get refunds.

Each source is checked when the oracle owner adds it. A feed must return a fresh positive answer, and a pool must pair the token with WETH and have enough history for the window.

**Trust assumption:** the oracle owner can change price sources, including for running campaigns. Use a multisig or timelock as owner before any real deployment.

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
- `lib/openzeppelin-contracts` (v5.7.0): `IERC20`, `SafeERC20`, `Ownable`, `ReentrancyGuard`
- `lib/v4-core` (v4.0.0): `FullMath` and `TickMath` (pure math libraries)

## Build and test

```sh
forge build
forge test            # add -vvv for traces
forge test --match-contract MixedCampaignTest
forge coverage
```

Unit tests use mock tokens, feeds and pools. The fork tests in `test/fork/` run against real mainnet Chainlink feeds and the Uniswap v3 USDC/WETH pool. They are skipped unless an RPC URL is set:

```sh
MAINNET_RPC_URL=https://... forge test --match-path "test/fork/*" -vvv
```

CI runs `forge build` and `forge test` on every push (`.github/workflows/test.yml`).

## Deploy

Copy `.env.example` to `.env`, fill it in, then `source .env`.

Local chain (Simple and Token campaigns; WETH can be any address):

```sh
anvil                         # in another terminal
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 WETH=0x0000000000000000000000000000000000000001 \
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
```

(That's anvil's first default account.) For mixed campaigns locally, run `anvil --fork-url $MAINNET_RPC_URL` and use the real WETH, feeds and pools.

Testnet: import your key once with `cast wallet import deployer --interactive`, then:

```sh
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast
```

Then, as `OWNER`, add price sources to the oracle:

```sh
# ETH/USD feed (needed for any USD-denominated token feed)
cast send $ORACLE "setEthUsdFeed(address,uint32)" <ethUsdFeed> 7200 --account deployer --rpc-url $SEPOLIA_RPC_URL
# Token feed: heartbeat in seconds, true if the feed is TOKEN/USD
cast send $ORACLE "setChainlinkFeed(address,address,uint32,bool)" <token> <feed> 90000 true --account deployer --rpc-url $SEPOLIA_RPC_URL
# Optional TWAP fallback: a Uniswap v3 token/WETH pool, window >= 1800 seconds
cast send $ORACLE "setTwapPool(address,address,uint32)" <token> <v3Pool> 1800 --account deployer --rpc-url $SEPOLIA_RPC_URL
```

Chainlink feed addresses and heartbeats are listed at https://docs.chain.link/data-feeds/price-feeds/addresses. Set each heartbeat slightly above the feed's published one.

## Version history

Each earlier version has its own branch with a README describing that stage:

- `V1.0.0`: single contract, ETH-only campaigns
- `V2.0.0`: factory + one contract per campaign, abort and pull-based refunds
- `V3.0.0`: single-token ERC-20 campaigns
- `main`: mixed ETH/token campaigns, deadlines, Chainlink/TWAP oracle, Foundry tooling
