// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @dev Chainlink-style feed with settable answer/timestamp.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public shouldRevert;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!shouldRevert, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Uniswap v3 pool stand-in whose TWAP is a fixed tick.
contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public tick;
    bool public noHistory;

    uint256 private constant BASE_TIME = 1_000_000_000;

    constructor(address tokenA, address tokenB, int24 tick_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        tick = tick_;
    }

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function setNoHistory(bool noHistory_) external {
        noHistory = noHistory_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!noHistory, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = int56(tick) * int56(uint56(BASE_TIME - secondsAgos[i]));
        }
    }
}

/// @dev IPriceOracle with a settable price, for campaign tests.
contract MockPriceOracle is IPriceOracle {
    mapping(address => bool) public supported;
    mapping(address => uint256) public weiPerToken; // wei per 1e18 base units
    bool public shouldRevert;

    function setPrice(address token, uint256 weiPerToken_) external {
        supported[token] = true;
        weiPerToken[token] = weiPerToken_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function isSupported(address token) external view returns (bool) {
        return supported[token];
    }

    function valueInWei(address token, uint256 amount) external view returns (uint256) {
        require(!shouldRevert, "price unavailable");
        require(supported[token], "unsupported");
        return amount * weiPerToken[token] / 1e18;
    }
}
