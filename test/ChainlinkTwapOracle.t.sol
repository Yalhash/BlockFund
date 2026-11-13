// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChainlinkTwapOracle} from "../src/oracles/ChainlinkTwapOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/external/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator, MockV3Pool} from "./mocks/MockOracles.sol";

contract ChainlinkTwapOracleTest is Test {
    ChainlinkTwapOracle oracle;
    MockERC20 weth;
    MockERC20 token; // 18 decimals
    MockERC20 usdc; // 6 decimals
    MockAggregator ethUsd;

    uint32 constant WINDOW = 30 minutes;
    /// @dev 1.0001^23027 ≈ 10, i.e. a 10x price.
    int24 constant TICK_10X = 23027;

    function setUp() public {
        weth = new MockERC20(18);
        token = new MockERC20(18);
        usdc = new MockERC20(6);

        oracle = new ChainlinkTwapOracle(address(this), address(weth));
        ethUsd = new MockAggregator(8, 2500e8); // $2,500 per ETH
        oracle.setEthUsdFeed(AggregatorV3Interface(address(ethUsd)), 1 hours);
    }

    function _feed(uint8 decimals, int256 answer) internal returns (AggregatorV3Interface) {
        return AggregatorV3Interface(address(new MockAggregator(decimals, answer)));
    }

    /// @dev Pool where `token` is worth 10 WETH, whichever way the addresses sort.
    function _pool10x() internal returns (MockV3Pool) {
        int24 tick = address(token) < address(weth) ? TICK_10X : -TICK_10X;
        return new MockV3Pool(address(token), address(weth), tick);
    }

    // ----- Chainlink valuation (bug 2: correct direction and precision) -----

    function test_Chainlink_EthDenominatedFeed() public {
        oracle.setChainlinkFeed(address(token), _feed(18, 0.0005e18), 1 days, false);
        // 1,000 tokens at 0.0005 ETH each = 0.5 ETH
        assertEq(oracle.valueInWei(address(token), 1_000e18), 0.5 ether);
    }

    function test_Chainlink_UsdFeed_SixDecimalToken() public {
        oracle.setChainlinkFeed(address(usdc), _feed(8, 1e8), 1 days, true);
        // 2,500 USDC at $1, ETH at $2,500 = 1 ETH. (The old code valued this at 0.)
        assertEq(oracle.valueInWei(address(usdc), 2_500e6), 1 ether);
    }

    function test_Chainlink_SmallAmountsDontRoundToZero() public {
        oracle.setChainlinkFeed(address(usdc), _feed(8, 1e8), 1 days, true);
        // 1 USDC = 1/2500 ETH = 0.0004 ETH
        assertEq(oracle.valueInWei(address(usdc), 1e6), 0.0004 ether);
    }

    // ----- TWAP valuation -----

    function test_Twap_TickZeroIsOneToOne() public {
        MockV3Pool pool = new MockV3Pool(address(token), address(weth), 0);
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(pool)), WINDOW);
        assertEq(oracle.valueInWei(address(token), 123e18), 123e18);
    }

    function test_Twap_TenXPrice() public {
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(_pool10x())), WINDOW);
        assertApproxEqRel(oracle.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_Twap_BothBranchesAgreeAcrossBoundary() public {
        // sqrtPrice crosses 2^128 at tick ~443636; check the two code paths line up.
        MockV3Pool pool = new MockV3Pool(address(token), address(weth), 443600);
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(pool)), WINDOW);
        uint256 amount = 1e40; // large enough that the token1 direction doesn't round to 0
        uint256 below = oracle.valueInWei(address(token), amount);

        pool.setTick(443700);
        uint256 above = oracle.valueInWei(address(token), amount);

        // Moving up 100 ticks scales the price by 1.0001^100 = 1.01004966...
        // token0: value = amount * price.  token1: value = amount / price.
        if (address(token) < address(weth)) {
            assertApproxEqRel(above, below * 10100497 / 10000000, 0.000001e18);
        } else {
            assertApproxEqRel(above, below * 10000000 / 10100497, 0.000001e18);
        }
    }

    // ----- Fallback order -----

    function test_Fallback_StaleChainlinkUsesTwap() public {
        oracle.setChainlinkFeed(address(token), _feed(18, 0.0005e18), 1 days, false);
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(_pool10x())), WINDOW);
        assertEq(oracle.valueInWei(address(token), 1e18), 0.0005e18, "fresh: Chainlink");

        vm.warp(block.timestamp + 1 days + 1);
        assertApproxEqRel(oracle.valueInWei(address(token), 1e18), 10e18, 0.001e18, "stale: TWAP");
    }

    function test_Fallback_RevertingFeedUsesTwap() public {
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(_pool10x())), WINDOW);

        MockAggregator(address(feed)).setShouldRevert(true);
        assertApproxEqRel(oracle.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_Fallback_NonPositiveAnswerUsesTwap() public {
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(_pool10x())), WINDOW);

        MockAggregator(address(feed)).setAnswer(0);
        assertApproxEqRel(oracle.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_RevertWhen_StaleChainlinkAndNoTwap() public {
        oracle.setChainlinkFeed(address(token), _feed(18, 0.0005e18), 1 days, false);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.PriceUnavailable.selector, address(token)));
        oracle.valueInWei(address(token), 1e18);
    }

    function test_RevertWhen_NoSource() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.PriceUnavailable.selector, address(token)));
        oracle.valueInWei(address(token), 1e18);
    }

    function test_Weth_IsOneToOne() public view {
        assertTrue(oracle.isSupported(address(weth)));
        assertEq(oracle.valueInWei(address(weth), 7e18), 7e18);
    }

    function test_IsSupported() public {
        assertFalse(oracle.isSupported(address(token)));
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(_pool10x())), WINDOW);
        assertTrue(oracle.isSupported(address(token)));
        oracle.removeTwapPool(address(token));
        assertFalse(oracle.isSupported(address(token)));
    }

    // ----- Bug 4: sources are validated when configured -----

    function test_RevertWhen_FeedHasNoValidAnswer() public {
        AggregatorV3Interface feed = _feed(18, 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.FeedUnusable.selector, address(feed)));
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);
    }

    function test_RevertWhen_FeedIsStaleAtSetup() public {
        vm.warp(10 days);
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        MockAggregator(address(feed)).setUpdatedAt(block.timestamp - 2 days);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.FeedUnusable.selector, address(feed)));
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);
    }

    function test_RevertWhen_ZeroHeartbeat() public {
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        vm.expectRevert(ChainlinkTwapOracle.InvalidHeartbeat.selector);
        oracle.setChainlinkFeed(address(token), feed, 0, false);
    }

    function test_RevertWhen_UsdFeedWithoutEthUsd() public {
        ChainlinkTwapOracle fresh = new ChainlinkTwapOracle(address(this), address(weth));
        AggregatorV3Interface feed = _feed(8, 1e8);
        vm.expectRevert(ChainlinkTwapOracle.EthUsdFeedNotSet.selector);
        fresh.setChainlinkFeed(address(usdc), feed, 1 days, true);
    }

    function test_RevertWhen_PoolIsForWrongPair() public {
        MockV3Pool wrong = new MockV3Pool(address(token), address(usdc), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkTwapOracle.PoolDoesNotPairTokenWithWeth.selector, address(wrong), address(token)
            )
        );
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(wrong)), WINDOW);
    }

    function test_RevertWhen_PoolPairsWethWithDifferentToken() public {
        MockV3Pool usdcPool = new MockV3Pool(address(usdc), address(weth), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkTwapOracle.PoolDoesNotPairTokenWithWeth.selector, address(usdcPool), address(token)
            )
        );
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(usdcPool)), WINDOW);
    }

    function test_RevertWhen_TwapWindowTooShort() public {
        MockV3Pool pool = _pool10x();
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkTwapOracle.TwapWindowTooShort.selector, uint32(29 minutes), WINDOW)
        );
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(pool)), 29 minutes);
    }

    function test_RevertWhen_PoolLacksHistory() public {
        MockV3Pool pool = _pool10x();
        pool.setNoHistory(true);
        vm.expectRevert(bytes("OLD"));
        oracle.setTwapPool(address(token), IUniswapV3Pool(address(pool)), WINDOW);
    }

    function test_TwoStepTransfer() public {
        address multisig = makeAddr("multisig");
        oracle.transferOwnership(multisig);
        assertEq(oracle.owner(), address(this));

        vm.prank(multisig);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), multisig);

        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);

        vm.prank(multisig);
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);
        assertTrue(oracle.isSupported(address(token)));
    }

    function test_RevertWhen_NonOwnerConfigures() public {
        address stranger = makeAddr("stranger");
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        oracle.setChainlinkFeed(address(token), feed, 1 days, false);
    }
}
