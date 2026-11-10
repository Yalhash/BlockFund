// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChainlinkTwapOracle} from "../../src/oracles/ChainlinkTwapOracle.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/IUniswapV3Pool.sol";

interface IUniswapV3PoolSwap {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256 amount0, int256 amount1);
}

/**
 * @notice Runs against real Ethereum mainnet contracts. Skipped unless MAINNET_RPC_URL is set:
 *   MAINNET_RPC_URL=https://... forge test --match-path test/fork/*
 */
contract OracleMainnetForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WETH_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // v3, 0.05% fee
    address constant USDC_ETH_FEED = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4; // Chainlink USDC/ETH
    address constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // Chainlink USDC/USD
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH/USD

    uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    bool forkActive;

    modifier onlyFork() {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forkActive = true;
    }

    function _chainlinkEthOracle() internal returns (ChainlinkTwapOracle o) {
        o = new ChainlinkTwapOracle(address(this), WETH);
        o.setChainlinkFeed(USDC, AggregatorV3Interface(USDC_ETH_FEED), 25 hours, false);
    }

    function _chainlinkUsdOracle() internal returns (ChainlinkTwapOracle o) {
        o = new ChainlinkTwapOracle(address(this), WETH);
        o.setEthUsdFeed(AggregatorV3Interface(ETH_USD_FEED), 2 hours);
        o.setChainlinkFeed(USDC, AggregatorV3Interface(USDC_USD_FEED), 25 hours, true);
    }

    function _twapOracle() internal returns (ChainlinkTwapOracle o) {
        o = new ChainlinkTwapOracle(address(this), WETH);
        o.setTwapPool(USDC, IUniswapV3Pool(USDC_WETH_POOL), 30 minutes);
    }

    /// @dev All three price paths should agree on what 10,000 USDC is worth.
    function test_Fork_SourcesAgree() public onlyFork {
        uint256 viaEthFeed = _chainlinkEthOracle().valueInWei(USDC, 10_000e6);
        uint256 viaUsdFeeds = _chainlinkUsdOracle().valueInWei(USDC, 10_000e6);
        uint256 viaTwap = _twapOracle().valueInWei(USDC, 10_000e6);

        assertGt(viaEthFeed, 0);
        assertApproxEqRel(viaUsdFeeds, viaEthFeed, 0.02e18, "USD feeds vs ETH feed");
        assertApproxEqRel(viaTwap, viaEthFeed, 0.02e18, "TWAP vs ETH feed");
    }

    /// @dev Bug 3: a huge swap moves the pool's spot price, but not the TWAP, in the same block.
    function test_Fork_SameBlockSwapDoesNotMoveTwap() public onlyFork {
        ChainlinkTwapOracle oracle = _twapOracle();
        uint256 valueBefore = oracle.valueInWei(USDC, 10_000e6);
        (, int24 spotTickBefore,,,,,) = IUniswapV3PoolSwap(USDC_WETH_POOL).slot0();

        // Dump 20,000 WETH into the pool (what a flash-loan attacker would do).
        deal(WETH, address(this), 20_000 ether);
        IUniswapV3PoolSwap(USDC_WETH_POOL).swap(
            address(this), false, int256(20_000 ether), MAX_SQRT_RATIO_MINUS_ONE, ""
        );

        (, int24 spotTickAfter,,,,,) = IUniswapV3PoolSwap(USDC_WETH_POOL).slot0();
        assertTrue(spotTickAfter > spotTickBefore + 1000, "spot price moved a lot");
        assertEq(oracle.valueInWei(USDC, 10_000e6), valueBefore, "TWAP unchanged");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == USDC_WETH_POOL, "not pool");
        if (amount0Delta > 0) IERC20(USDC).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(WETH).transfer(msg.sender, uint256(amount1Delta));
    }
}
