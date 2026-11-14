// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

/// @title Price oracle used by campaigns to value token donations in ETH.
/// @dev Implementations must not rely on a pool's current (spot) price, which can be
///      moved inside a single transaction with a flash loan.
interface IPriceOracle {
    /// @return True if `token` can currently be priced (a price source is configured).
    function isSupported(address token) external view returns (bool);

    /// @notice Value of `amount` base units of `token`, expressed in wei.
    /// @dev Reverts if no usable price source is available.
    function valueInWei(address token, uint256 amount) external view returns (uint256);
}
