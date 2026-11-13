# BlockFund

A crypto crowdfunding platform. A `BlockFund` factory contract deploys one contract per campaign. Campaigns are all-or-nothing with a deadline: if the goal is reached the owner collects, otherwise every donor withdraws their own donation.

> **Status: experimental, unaudited.** Don't deploy to mainnet with real funds.

## How a campaign works

1. Someone creates a campaign through `BlockFund` with an owner, a goal and a deadline (at most 365 days away).
2. Donors give until the deadline. Token donations need `token.approve(campaign, amount)` first.
3. **Goal reached:** the owner can call `settleCampaign()` at any time. After the deadline, *anyone* can, so funds never sit idle. Settling only records the outcome; the owner then calls `claimFunds(to)` to collect everything at an address of their choice.
4. **Goal missed by the deadline, or the owner calls `abortCampaign()`:** refunds open. Each donor calls `withdrawDonation(to)` and gets back exactly what they gave, in the asset they gave, at an address of their choice (normally their own).
5. The first settle or refund fixes the outcome (`state` becomes `Settled` or `Refunding`) and it never changes after that.

Payouts and refunds are *pulled* by the recipient rather than pushed. A recipient that can't receive the funds (a contract without a `receive()` function, or an address a token like USDC has blacklisted) can't block the campaign: it just withdraws to a different address.

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

**Trust assumption:** the oracle owner can change price sources, including for running campaigns. That's why the owner of both the oracle and the factory is a multisig (see [Admin](#admin-multisig)).

Campaign owners are a single address for now (any wallet or contract). Multisig-owned campaigns already work if the owner address is a Safe; dedicated support in the front-end is planned.

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

### Local chain

On anvil (chain id 31337) the owner can be a plain wallet. WETH can be any address unless you use mixed campaigns.

```sh
anvil                         # in another terminal
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 WETH=0x0000000000000000000000000000000000000001 \
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
```

(That's anvil's first default account; it can then configure the oracle directly with `cast send`.) For mixed campaigns locally, run `anvil --fork-url $MAINNET_RPC_URL` and use the real WETH, feeds and pools.

### Testnet / mainnet

1. Create the admin Safe first (see below) and put its address in `OWNER`. The deploy script refuses to run if `OWNER` has no contract code on the target chain.
2. Import a deployer key once with `cast wallet import deployer --interactive`. It only pays gas and has no admin rights afterwards.
3. Deploy:

   ```sh
   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast
   ```

## Admin (multisig)

The oracle and the factory are owned by a [Safe](https://app.safe.global) multisig, so admin actions need several approvals and no single leaked key can change price sources.

### Create the Safe

1. Open https://app.safe.global, connect MetaMask, and pick the network.
2. Add the signer addresses (e.g. three MetaMask accounts, ideally on different devices or with different people) and a threshold (e.g. 2 of 3).
3. Confirm the deployment transaction. The Safe's address is your `OWNER`.

On a testnet you can hold all the signer keys yourself as separate MetaMask accounts.

### Configure price sources

Admin calls go through the Safe's **Transaction Builder** (Apps, then Transaction Builder):

1. Enter the oracle's address. Paste its ABI from `out/ChainlinkTwapOracle.sol/ChainlinkTwapOracle.json` (the `abi` field) if it isn't verified on the block explorer.
2. Add a call per change and put them all in one batch:
   - `setEthUsdFeed(feed, heartbeat)` first, if any token uses a USD feed
   - `setChainlinkFeed(token, feed, heartbeat, usdDenominated)`
   - optionally `setTwapPool(token, v3Pool, window)` with a window of at least 1800 seconds
3. Create the batch. The other signers approve it in the Safe app, and the last one executes it.

Chainlink feed addresses and heartbeats are listed at https://docs.chain.link/data-feeds/price-feeds/addresses. Set each heartbeat slightly above the feed's published one.

### Changing the admin

Ownership transfers are two-step. The current owner calls `transferOwnership(newOwner)`; nothing changes until `newOwner` calls `acceptOwnership()`. A typo'd address therefore can't take over (or lock) admin rights. To move to a new Safe, run both steps as Safe transactions.

## Version history

Each earlier version has its own branch with a README describing that stage:

- `V1.0.0`: single contract, ETH-only campaigns
- `V2.0.0`: factory + one contract per campaign, abort and pull-based refunds
- `V3.0.0`: single-token ERC-20 campaigns
- `main`: mixed ETH/token campaigns, deadlines, Chainlink/TWAP oracle, Foundry tooling
