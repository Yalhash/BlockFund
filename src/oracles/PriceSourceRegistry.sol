// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IPriceSourceRegistry} from "../interfaces/IPriceSourceRegistry.sol";
import {ChainlinkTwapOracle} from "./ChainlinkTwapOracle.sol";

/**
 * @title Price source registry
 * @notice Records which oracle new mixed campaigns use for each token.
 * @dev The admin (a multisig) can add, replace, or remove a token's entry, but every entry
 *      points to an immutable, ownerless ChainlinkTwapOracle deployed by this contract.
 *      Campaigns copy the oracle address when they're created, so registry changes only
 *      affect campaigns created afterwards. Nobody can change the price sources of a
 *      campaign that already exists.
 *
 *      Ownership transfers are two-step: `transferOwnership(new)`, then the new owner
 *      calls `acceptOwnership()`.
 */
contract PriceSourceRegistry is IPriceSourceRegistry, Ownable2Step {
    address public immutable weth;

    /// @inheritdoc IPriceSourceRegistry
    mapping(address token => IPriceOracle) public oracleFor;

    event SourceSet(address indexed token, address oracle);
    event SourceRemoved(address indexed token);

    error ZeroAddress();

    constructor(address initialOwner, address weth_) Ownable(initialOwner) {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
    }

    /// @notice Deploys a new immutable oracle for `token` and makes it the one new campaigns use.
    ///         Replaces any previous entry; campaigns already using the old oracle keep it.
    /// @dev Reverts if a source fails validation (see ChainlinkTwapOracle's constructor).
    ///      Pass a zero `chainlink.feed` or zero `twap.pool` to leave that source out.
    function setSource(
        address token,
        ChainlinkTwapOracle.ChainlinkParams calldata chainlink,
        ChainlinkTwapOracle.TwapParams calldata twap
    ) external onlyOwner returns (IPriceOracle oracle) {
        oracle = new ChainlinkTwapOracle(token, weth, chainlink, twap);
        oracleFor[token] = oracle;
        emit SourceSet(token, address(oracle));
    }

    /// @notice Stops new mixed campaigns for `token`. Existing campaigns are unaffected.
    function removeSource(address token) external onlyOwner {
        delete oracleFor[token];
        emit SourceRemoved(token);
    }
}
