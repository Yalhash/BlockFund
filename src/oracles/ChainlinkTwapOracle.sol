// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "../interfaces/external/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";

/**
 * @title Chainlink + Uniswap v3 TWAP price oracle
 * @notice Values tokens in wei. Chainlink is the primary source; if a token's feed is
 *         missing, stale, or broken, a Uniswap v3 time-weighted average price (TWAP)
 *         against WETH is used instead.
 * @dev Neither source can be moved by a flash loan: Chainlink is aggregated off-chain,
 *      and a TWAP averages over past blocks (at least MIN_TWAP_WINDOW).
 *      Every source is validated when it's configured, so a typo or a pool for the
 *      wrong pair is rejected up front rather than silently pricing tokens at 0.
 *
 *      Trust: the owner can change price sources, including for campaigns that are
 *      already running. It should be a multisig (e.g. a Safe); ownership transfers are
 *      two-step (`transferOwnership`, then `acceptOwnership` by the new owner).
 */
contract ChainlinkTwapOracle is IPriceOracle, Ownable2Step {
    struct Feed {
        AggregatorV3Interface feed;
        uint32 heartbeat; // max age (seconds) before an answer counts as stale
        uint8 feedDecimals;
        bool usdDenominated; // true: TOKEN/USD (converted via ETH/USD). false: TOKEN/ETH
    }

    struct Twap {
        IUniswapV3Pool pool; // a token/WETH pool
        uint32 window; // averaging window in seconds
    }

    uint32 public constant MIN_TWAP_WINDOW = 30 minutes;

    /// @notice Wrapped ETH. Valued 1:1 with ETH, and the quote asset for all TWAP pools.
    address public immutable weth;

    Feed public ethUsdFeed;
    mapping(address token => Feed) public chainlinkFeeds;
    mapping(address token => Twap) public twapPools;
    mapping(address token => uint8) public tokenDecimals;

    event EthUsdFeedSet(address feed, uint32 heartbeat);
    event ChainlinkFeedSet(address indexed token, address feed, uint32 heartbeat, bool usdDenominated);
    event ChainlinkFeedRemoved(address indexed token);
    event TwapPoolSet(address indexed token, address pool, uint32 window);
    event TwapPoolRemoved(address indexed token);

    error ZeroAddress();
    error InvalidHeartbeat();
    error FeedUnusable(address feed);
    error EthUsdFeedNotSet();
    error TwapWindowTooShort(uint32 window, uint32 minimum);
    error PoolDoesNotPairTokenWithWeth(address pool, address token);
    error PriceUnavailable(address token);

    constructor(address initialOwner, address weth_) Ownable(initialOwner) {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
    }

    // ---------------------------------------------------------------------
    // Configuration (owner only). Each setter checks the source works now.
    // ---------------------------------------------------------------------

    /// @notice ETH/USD feed, needed to convert USD-denominated token feeds into ETH.
    function setEthUsdFeed(AggregatorV3Interface feed, uint32 heartbeat) external onlyOwner {
        Feed memory f = _newFeed(feed, heartbeat, false);
        (bool ok,) = _readFeed(f);
        if (!ok) revert FeedUnusable(address(feed));
        ethUsdFeed = f;
        emit EthUsdFeedSet(address(feed), heartbeat);
    }

    /// @param usdDenominated true for a TOKEN/USD feed, false for a TOKEN/ETH feed.
    function setChainlinkFeed(address token, AggregatorV3Interface feed, uint32 heartbeat, bool usdDenominated)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (usdDenominated && address(ethUsdFeed.feed) == address(0)) revert EthUsdFeedNotSet();

        Feed memory f = _newFeed(feed, heartbeat, usdDenominated);
        (bool ok,) = _readFeed(f);
        if (!ok) revert FeedUnusable(address(feed));

        tokenDecimals[token] = IERC20Metadata(token).decimals();
        chainlinkFeeds[token] = f;
        emit ChainlinkFeedSet(token, address(feed), heartbeat, usdDenominated);
    }

    function removeChainlinkFeed(address token) external onlyOwner {
        delete chainlinkFeeds[token];
        emit ChainlinkFeedRemoved(token);
    }

    /// @notice Uniswap v3 token/WETH pool used when the Chainlink feed is unavailable.
    function setTwapPool(address token, IUniswapV3Pool pool, uint32 window) external onlyOwner {
        if (token == address(0) || address(pool) == address(0)) revert ZeroAddress();
        if (window < MIN_TWAP_WINDOW) revert TwapWindowTooShort(window, MIN_TWAP_WINDOW);

        address token0 = pool.token0();
        address token1 = pool.token1();
        bool pairsTokenWithWeth = (token0 == token && token1 == weth) || (token0 == weth && token1 == token);
        if (!pairsTokenWithWeth) revert PoolDoesNotPairTokenWithWeth(address(pool), token);

        // Reverts ("OLD") if the pool doesn't keep enough history for this window yet.
        _twapTick(pool, window);

        twapPools[token] = Twap(pool, window);
        emit TwapPoolSet(token, address(pool), window);
    }

    function removeTwapPool(address token) external onlyOwner {
        delete twapPools[token];
        emit TwapPoolRemoved(token);
    }

    // ---------------------------------------------------------------------
    // IPriceOracle
    // ---------------------------------------------------------------------

    function isSupported(address token) external view returns (bool) {
        return token == weth || address(chainlinkFeeds[token].feed) != address(0)
            || address(twapPools[token].pool) != address(0);
    }

    function valueInWei(address token, uint256 amount) external view returns (uint256) {
        if (amount == 0 || token == weth) return amount;

        Feed memory feed = chainlinkFeeds[token];
        if (address(feed.feed) != address(0)) {
            (bool ok, uint256 value) = _chainlinkValue(token, amount, feed);
            if (ok) return value;
        }

        Twap memory twap = twapPools[token];
        if (address(twap.pool) != address(0)) {
            return _twapValue(token, amount, twap);
        }

        revert PriceUnavailable(token);
    }

    // ---------------------------------------------------------------------
    // Chainlink
    // ---------------------------------------------------------------------

    function _newFeed(AggregatorV3Interface feed, uint32 heartbeat, bool usdDenominated)
        internal
        view
        returns (Feed memory)
    {
        if (address(feed) == address(0)) revert ZeroAddress();
        if (heartbeat == 0) revert InvalidHeartbeat();
        return Feed(feed, heartbeat, feed.decimals(), usdDenominated);
    }

    /// @dev Never reverts for a configured feed: returns ok=false on a bad, stale, or reverting read.
    function _readFeed(Feed memory f) internal view returns (bool ok, uint256 price) {
        try f.feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (false, 0);
            if (block.timestamp - updatedAt > f.heartbeat) return (false, 0);
            return (true, uint256(answer));
        } catch {
            return (false, 0);
        }
    }

    function _chainlinkValue(address token, uint256 amount, Feed memory f)
        internal
        view
        returns (bool ok, uint256 valueWei)
    {
        (bool priceOk, uint256 price) = _readFeed(f);
        if (!priceOk) return (false, 0);

        // amount / 10^tokenDecimals * price / 10^feedDecimals, scaled to 18 decimals
        uint256 scale = 10 ** (uint256(tokenDecimals[token]) + f.feedDecimals);
        uint256 value18 = FullMath.mulDiv(amount, price * 1e18, scale);

        if (!f.usdDenominated) return (true, value18); // already ETH, 18 decimals = wei

        Feed memory e = ethUsdFeed;
        (bool ethOk, uint256 ethUsd) = _readFeed(e);
        if (!ethOk) return (false, 0);
        // value18 is USD with 18 decimals; divide by the ETH price to get wei
        return (true, FullMath.mulDiv(value18, 10 ** e.feedDecimals, ethUsd));
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
    function _twapValue(address token, uint256 amount, Twap memory t) internal view returns (uint256) {
        int24 tick = _twapTick(t.pool, t.window);
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
