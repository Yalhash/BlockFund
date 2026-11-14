// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "../interfaces/external/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";

/**
 * @title Chainlink + Uniswap v3 TWAP price oracle for one token
 * @notice Values `token` in wei. Chainlink is the primary source; if its feed is stale,
 *         broken, or missing, a Uniswap v3 time-weighted average price (TWAP) against WETH
 *         is used instead. WETH is always valued 1:1.
 * @dev Immutable and ownerless: every setting is fixed at deployment and nobody can change
 *      it afterwards. A campaign that stores this oracle's address therefore keeps exactly
 *      the price sources it was created with. To use different sources for *new*
 *      campaigns, deploy a new instance (see PriceSourceRegistry).
 *
 *      Neither source can be moved by a flash loan: Chainlink is aggregated off-chain,
 *      and a TWAP averages over past blocks (at least MIN_TWAP_WINDOW). Each source is
 *      validated in the constructor, so a typo or a pool for the wrong pair can't be
 *      deployed.
 *
 *      If a feed is later retired (stops updating), it counts as stale and the TWAP is
 *      used; if no source works, campaigns can't settle and refunds open after the deadline.
 */
contract ChainlinkTwapOracle is IPriceOracle {
    struct ChainlinkParams {
        AggregatorV3Interface feed; // zero address = no Chainlink source
        uint32 heartbeat; // max age (seconds) before an answer counts as stale
        bool usdDenominated; // true: TOKEN/USD feed (converted via ethUsdFeed). false: TOKEN/ETH
        AggregatorV3Interface ethUsdFeed; // required if usdDenominated, ignored otherwise
        uint32 ethUsdHeartbeat;
    }

    struct TwapParams {
        IUniswapV3Pool pool; // a token/WETH pool; zero address = no TWAP source
        uint32 window; // averaging window in seconds, at least MIN_TWAP_WINDOW
    }

    uint32 public constant MIN_TWAP_WINDOW = 30 minutes;

    address public immutable token;
    /// @notice Wrapped ETH: valued 1:1 with ETH and the quote asset of the TWAP pool.
    address public immutable weth;
    uint8 public immutable tokenDecimals;

    AggregatorV3Interface public immutable feed;
    uint32 public immutable heartbeat;
    uint8 public immutable feedDecimals;
    bool public immutable usdDenominated;
    AggregatorV3Interface public immutable ethUsdFeed;
    uint32 public immutable ethUsdHeartbeat;
    uint8 public immutable ethUsdDecimals;

    IUniswapV3Pool public immutable twapPool;
    uint32 public immutable twapWindow;

    error ZeroAddress();
    error NoPriceSource();
    error InvalidHeartbeat();
    error FeedUnusable(address feed);
    error EthUsdFeedNotSet();
    error TwapWindowTooShort(uint32 window, uint32 minimum);
    error PoolDoesNotPairTokenWithWeth(address pool, address token);
    error UnsupportedToken(address token);
    error PriceUnavailable(address token);

    constructor(address token_, address weth_, ChainlinkParams memory chainlink, TwapParams memory twap) {
        if (token_ == address(0) || weth_ == address(0)) revert ZeroAddress();

        bool hasFeed = address(chainlink.feed) != address(0);
        bool hasTwap = address(twap.pool) != address(0);
        // WETH needs no source (it's 1:1); every other token needs at least one.
        if (!hasFeed && !hasTwap && token_ != weth_) revert NoPriceSource();

        bool usd = hasFeed && chainlink.usdDenominated;
        uint8 fDecimals;
        uint8 eDecimals;
        uint8 tDecimals;
        if (hasFeed) {
            fDecimals = _validateFeed(chainlink.feed, chainlink.heartbeat);
            tDecimals = IERC20Metadata(token_).decimals();
            if (usd) {
                if (address(chainlink.ethUsdFeed) == address(0)) revert EthUsdFeedNotSet();
                eDecimals = _validateFeed(chainlink.ethUsdFeed, chainlink.ethUsdHeartbeat);
            }
        }

        if (hasTwap) {
            if (twap.window < MIN_TWAP_WINDOW) revert TwapWindowTooShort(twap.window, MIN_TWAP_WINDOW);
            address token0 = twap.pool.token0();
            address token1 = twap.pool.token1();
            bool pairsTokenWithWeth = (token0 == token_ && token1 == weth_) || (token0 == weth_ && token1 == token_);
            if (!pairsTokenWithWeth) revert PoolDoesNotPairTokenWithWeth(address(twap.pool), token_);
            // Reverts ("OLD") if the pool doesn't keep enough history for this window yet.
            _twapTick(twap.pool, twap.window);
        }

        token = token_;
        weth = weth_;
        tokenDecimals = tDecimals;

        feed = chainlink.feed;
        heartbeat = hasFeed ? chainlink.heartbeat : 0;
        feedDecimals = fDecimals;
        usdDenominated = usd;
        ethUsdFeed = usd ? chainlink.ethUsdFeed : AggregatorV3Interface(address(0));
        ethUsdHeartbeat = usd ? chainlink.ethUsdHeartbeat : 0;
        ethUsdDecimals = eDecimals;

        twapPool = twap.pool;
        twapWindow = hasTwap ? twap.window : 0;
    }

    // ---------------------------------------------------------------------
    // IPriceOracle
    // ---------------------------------------------------------------------

    function isSupported(address asset) external view returns (bool) {
        return asset == token || asset == weth;
    }

    function valueInWei(address asset, uint256 amount) external view returns (uint256) {
        if (amount == 0 || asset == weth) return amount;
        if (asset != token) revert UnsupportedToken(asset);

        if (address(feed) != address(0)) {
            (bool ok, uint256 value) = _chainlinkValue(amount);
            if (ok) return value;
        }
        if (address(twapPool) != address(0)) {
            return _twapValue(amount);
        }
        revert PriceUnavailable(asset);
    }

    // ---------------------------------------------------------------------
    // Chainlink
    // ---------------------------------------------------------------------

    function _validateFeed(AggregatorV3Interface f, uint32 maxAge) internal view returns (uint8 decimals) {
        if (maxAge == 0) revert InvalidHeartbeat();
        decimals = f.decimals();
        (bool ok,) = _readFeed(f, maxAge);
        if (!ok) revert FeedUnusable(address(f));
    }

    /// @dev Never reverts: returns ok=false on a bad, stale, or reverting read.
    function _readFeed(AggregatorV3Interface f, uint32 maxAge) internal view returns (bool ok, uint256 price) {
        try f.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (false, 0);
            if (block.timestamp - updatedAt > maxAge) return (false, 0);
            return (true, uint256(answer));
        } catch {
            return (false, 0);
        }
    }

    function _chainlinkValue(uint256 amount) internal view returns (bool ok, uint256 valueWei) {
        (bool priceOk, uint256 price) = _readFeed(feed, heartbeat);
        if (!priceOk) return (false, 0);

        // amount / 10^tokenDecimals * price / 10^feedDecimals, scaled to 18 decimals
        uint256 scale = 10 ** (uint256(tokenDecimals) + feedDecimals);
        uint256 value18 = FullMath.mulDiv(amount, price * 1e18, scale);

        if (!usdDenominated) return (true, value18); // already ETH with 18 decimals = wei

        (bool ethOk, uint256 ethUsd) = _readFeed(ethUsdFeed, ethUsdHeartbeat);
        if (!ethOk) return (false, 0);
        // value18 is USD with 18 decimals; divide by the ETH price to get wei
        return (true, FullMath.mulDiv(value18, 10 ** ethUsdDecimals, ethUsd));
    }

    // ---------------------------------------------------------------------
    // Uniswap v3 TWAP (same math as v3-periphery's OracleLibrary)
    // ---------------------------------------------------------------------

    /// @dev Arithmetic mean tick over the last `window` seconds, rounded toward negative infinity.
    function _twapTick(IUniswapV3Pool pool, uint32 window) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window; // secondsAgos[1] = 0 (now)

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 w = int56(uint56(window));

        tick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) tick--;
    }

    /// @dev Converts `amount` of `token` into WETH (= wei) at the TWAP tick.
    ///      A tick's price is token1 per token0 in raw units, so decimals cancel out.
    function _twapValue(uint256 amount) internal view returns (uint256) {
        int24 tick = _twapTick(twapPool, twapWindow);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        bool tokenIsToken0 = token < weth; // v3 pools sort tokens by address

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            return tokenIsToken0
                ? FullMath.mulDiv(ratioX192, amount, 1 << 192)
                : FullMath.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return tokenIsToken0
            ? FullMath.mulDiv(ratioX128, amount, 1 << 128)
            : FullMath.mulDiv(1 << 128, amount, ratioX128);
    }
}
