// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @dev The subset of the Uniswap v3 pool interface needed for TWAP reads.
interface IUniswapV3Pool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    /// @notice Cumulative tick values as of each `secondsAgos` from now.
    /// @dev Reverts with "OLD" if the pool doesn't have enough observation history.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
