// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkTwapOracle} from "../src/oracles/ChainlinkTwapOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/external/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator, MockV3Pool} from "./mocks/MockOracles.sol";

contract ChainlinkTwapOracleTest is Test {
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
        ethUsd = new MockAggregator(8, 2500e8); // $2,500 per ETH
    }

    // ----- helpers -----

    function _feed(uint8 decimals, int256 answer) internal returns (AggregatorV3Interface) {
        return AggregatorV3Interface(address(new MockAggregator(decimals, answer)));
    }

    function _ethFeed(AggregatorV3Interface feed) internal pure returns (ChainlinkTwapOracle.ChainlinkParams memory) {
        return ChainlinkTwapOracle.ChainlinkParams(feed, 1 days, false, AggregatorV3Interface(address(0)), 0);
    }

    function _usdFeed(AggregatorV3Interface feed) internal view returns (ChainlinkTwapOracle.ChainlinkParams memory) {
        return ChainlinkTwapOracle.ChainlinkParams(feed, 1 days, true, AggregatorV3Interface(address(ethUsd)), 1 hours);
    }

    function _noFeed() internal pure returns (ChainlinkTwapOracle.ChainlinkParams memory p) {}

    function _twap(MockV3Pool pool) internal pure returns (ChainlinkTwapOracle.TwapParams memory) {
        return ChainlinkTwapOracle.TwapParams(IUniswapV3Pool(address(pool)), WINDOW);
    }

    function _noTwap() internal pure returns (ChainlinkTwapOracle.TwapParams memory p) {}

    /// @dev Pool where `token` is worth 10 WETH, whichever way the addresses sort.
    function _pool10x() internal returns (MockV3Pool) {
        int24 tick = address(token) < address(weth) ? TICK_10X : -TICK_10X;
        return new MockV3Pool(address(token), address(weth), tick);
    }

    function _oracle(
        MockERC20 t,
        ChainlinkTwapOracle.ChainlinkParams memory chainlink,
        ChainlinkTwapOracle.TwapParams memory twap
    ) internal returns (ChainlinkTwapOracle) {
        return new ChainlinkTwapOracle(address(t), address(weth), chainlink, twap);
    }

    // ----- Chainlink valuation -----

    function test_Chainlink_EthDenominatedFeed() public {
        ChainlinkTwapOracle o = _oracle(token, _ethFeed(_feed(18, 0.0005e18)), _noTwap());
        // 1,000 tokens at 0.0005 ETH each = 0.5 ETH
        assertEq(o.valueInWei(address(token), 1_000e18), 0.5 ether);
    }

    function test_Chainlink_UsdFeed_SixDecimalToken() public {
        ChainlinkTwapOracle o = _oracle(usdc, _usdFeed(_feed(8, 1e8)), _noTwap());
        // 2,500 USDC at $1, ETH at $2,500 = 1 ETH
        assertEq(o.valueInWei(address(usdc), 2_500e6), 1 ether);
    }

    function test_Chainlink_SmallAmountsDontRoundToZero() public {
        ChainlinkTwapOracle o = _oracle(usdc, _usdFeed(_feed(8, 1e8)), _noTwap());
        // 1 USDC = 1/2500 ETH = 0.0004 ETH
        assertEq(o.valueInWei(address(usdc), 1e6), 0.0004 ether);
    }

    // ----- TWAP valuation -----

    function test_Twap_TickZeroIsOneToOne() public {
        MockV3Pool pool = new MockV3Pool(address(token), address(weth), 0);
        ChainlinkTwapOracle o = _oracle(token, _noFeed(), _twap(pool));
        assertEq(o.valueInWei(address(token), 123e18), 123e18);
    }

    function test_Twap_TenXPrice() public {
        ChainlinkTwapOracle o = _oracle(token, _noFeed(), _twap(_pool10x()));
        assertApproxEqRel(o.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_Twap_BothBranchesAgreeAcrossBoundary() public {
        // sqrtPrice crosses 2^128 at tick ~443636; check the two code paths line up.
        MockV3Pool pool = new MockV3Pool(address(token), address(weth), 443600);
        ChainlinkTwapOracle o = _oracle(token, _noFeed(), _twap(pool));
        uint256 amount = 1e40; // large enough that the token1 direction doesn't round to 0
        uint256 below = o.valueInWei(address(token), amount);

        pool.setTick(443700);
        uint256 above = o.valueInWei(address(token), amount);

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
        ChainlinkTwapOracle o = _oracle(token, _ethFeed(_feed(18, 0.0005e18)), _twap(_pool10x()));
        assertEq(o.valueInWei(address(token), 1e18), 0.0005e18, "fresh: Chainlink");

        vm.warp(block.timestamp + 1 days + 1);
        assertApproxEqRel(o.valueInWei(address(token), 1e18), 10e18, 0.001e18, "stale: TWAP");
    }

    function test_Fallback_RevertingFeedUsesTwap() public {
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        ChainlinkTwapOracle o = _oracle(token, _ethFeed(feed), _twap(_pool10x()));

        MockAggregator(address(feed)).setShouldRevert(true);
        assertApproxEqRel(o.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_Fallback_NonPositiveAnswerUsesTwap() public {
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        ChainlinkTwapOracle o = _oracle(token, _ethFeed(feed), _twap(_pool10x()));

        MockAggregator(address(feed)).setAnswer(0);
        assertApproxEqRel(o.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_Fallback_StaleEthUsdUsesTwap() public {
        ChainlinkTwapOracle o = _oracle(token, _usdFeed(_feed(8, 1e8)), _twap(_pool10x()));
        // Token feed (1 day heartbeat) still fresh, ETH/USD (1 hour) stale.
        vm.warp(block.timestamp + 2 hours);
        assertApproxEqRel(o.valueInWei(address(token), 1e18), 10e18, 0.001e18);
    }

    function test_RevertWhen_StaleChainlinkAndNoTwap() public {
        ChainlinkTwapOracle o = _oracle(token, _ethFeed(_feed(18, 0.0005e18)), _noTwap());
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.PriceUnavailable.selector, address(token)));
        o.valueInWei(address(token), 1e18);
    }

    // ----- Supported assets -----

    function test_Weth_IsOneToOne() public {
        ChainlinkTwapOracle o = _oracle(token, _noFeed(), _twap(_pool10x()));
        assertTrue(o.isSupported(address(weth)));
        assertEq(o.valueInWei(address(weth), 7e18), 7e18);
    }

    function test_WethOracle_NeedsNoSource() public {
        ChainlinkTwapOracle o = _oracle(weth, _noFeed(), _noTwap());
        assertEq(o.valueInWei(address(weth), 3e18), 3e18);
    }

    function test_RevertWhen_PricingAnotherToken() public {
        ChainlinkTwapOracle o = _oracle(token, _noFeed(), _twap(_pool10x()));
        assertFalse(o.isSupported(address(usdc)));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.UnsupportedToken.selector, address(usdc)));
        o.valueInWei(address(usdc), 1e6);
    }

    // ----- Immutability: the settings are read-only -----

    function test_SettingsAreFixedAtDeployment() public {
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        MockV3Pool pool = _pool10x();
        ChainlinkTwapOracle o = _oracle(token, _ethFeed(feed), _twap(pool));

        assertEq(o.token(), address(token));
        assertEq(address(o.feed()), address(feed));
        assertEq(o.heartbeat(), 1 days);
        assertEq(address(o.twapPool()), address(pool));
        assertEq(o.twapWindow(), WINDOW);
        // There is no owner and no setter: nothing to call to change these.
    }

    // ----- Validation at deployment (bug 4) -----

    function test_RevertWhen_NoSource() public {
        vm.expectRevert(ChainlinkTwapOracle.NoPriceSource.selector);
        _oracle(token, _noFeed(), _noTwap());
    }

    function test_RevertWhen_FeedHasNoValidAnswer() public {
        AggregatorV3Interface feed = _feed(18, 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.FeedUnusable.selector, address(feed)));
        _oracle(token, _ethFeed(feed), _noTwap());
    }

    function test_RevertWhen_FeedIsStaleAtDeployment() public {
        vm.warp(10 days);
        AggregatorV3Interface feed = _feed(18, 0.0005e18);
        MockAggregator(address(feed)).setUpdatedAt(block.timestamp - 2 days);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.FeedUnusable.selector, address(feed)));
        _oracle(token, _ethFeed(feed), _noTwap());
    }

    function test_RevertWhen_ZeroHeartbeat() public {
        ChainlinkTwapOracle.ChainlinkParams memory p = _ethFeed(_feed(18, 0.0005e18));
        p.heartbeat = 0;
        vm.expectRevert(ChainlinkTwapOracle.InvalidHeartbeat.selector);
        _oracle(token, p, _noTwap());
    }

    function test_RevertWhen_UsdFeedWithoutEthUsd() public {
        ChainlinkTwapOracle.ChainlinkParams memory p = _usdFeed(_feed(8, 1e8));
        p.ethUsdFeed = AggregatorV3Interface(address(0));
        vm.expectRevert(ChainlinkTwapOracle.EthUsdFeedNotSet.selector);
        _oracle(usdc, p, _noTwap());
    }

    function test_RevertWhen_PoolIsForWrongPair() public {
        MockV3Pool wrong = new MockV3Pool(address(token), address(usdc), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkTwapOracle.PoolDoesNotPairTokenWithWeth.selector, address(wrong), address(token)
            )
        );
        _oracle(token, _noFeed(), _twap(wrong));
    }

    function test_RevertWhen_PoolPairsWethWithDifferentToken() public {
        MockV3Pool usdcPool = new MockV3Pool(address(usdc), address(weth), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkTwapOracle.PoolDoesNotPairTokenWithWeth.selector, address(usdcPool), address(token)
            )
        );
        _oracle(token, _noFeed(), _twap(usdcPool));
    }

    function test_RevertWhen_TwapWindowTooShort() public {
        ChainlinkTwapOracle.TwapParams memory p = _twap(_pool10x());
        p.window = 29 minutes;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkTwapOracle.TwapWindowTooShort.selector, uint32(29 minutes), WINDOW)
        );
        _oracle(token, _noFeed(), p);
    }

    function test_RevertWhen_PoolLacksHistory() public {
        MockV3Pool pool = _pool10x();
        pool.setNoHistory(true);
        vm.expectRevert(bytes("OLD"));
        _oracle(token, _noFeed(), _twap(pool));
    }
}
