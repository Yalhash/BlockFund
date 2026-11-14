// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @title Lookup of the price oracle new campaigns should use for each token.
interface IPriceSourceRegistry {
    /// @return The oracle for `token`, or the zero address if the token isn't supported.
    function oracleFor(address token) external view returns (IPriceOracle);
}
