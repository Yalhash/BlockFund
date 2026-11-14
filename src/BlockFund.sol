// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SimpleCampaign} from "./SimpleCampaign.sol";
import {TokenCampaign} from "./TokenCampaign.sol";
import {MixedCampaign} from "./MixedCampaign.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IPriceSourceRegistry} from "./interfaces/IPriceSourceRegistry.sol";

/**
 * @title Block Fund
 * @notice Factory that deploys one contract per campaign. Anyone can create a campaign.
 * @dev Mixed campaigns are limited to tokens listed in the price source registry. A mixed
 *      campaign copies the token's oracle address when it's created, and those oracles are
 *      immutable, so nobody (including the admin) can change an existing campaign's price
 *      sources. The registry itself is fixed at deployment for the same reason.
 *
 *      The factory has no owner and no admin functions. The only admin surface is the
 *      registry, which is owned by a multisig.
 */
contract BlockFund {
    enum CampaignType {
        SIMPLE,
        TOKEN,
        MIXED
    }

    IPriceSourceRegistry public immutable registry;

    event CampaignCreated(address indexed campaign, CampaignType indexed campaignType, address indexed campaignOwner);

    error ZeroAddress();
    error UnsupportedToken(address token);

    constructor(IPriceSourceRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @param deadline Unix timestamp; must be in the future and within MAX_DURATION.
    function createSimpleCampaign(address payable campaignOwner, uint256 goalWei, uint256 deadline)
        external
        returns (address)
    {
        SimpleCampaign campaign = new SimpleCampaign(campaignOwner, goalWei, deadline);
        emit CampaignCreated(address(campaign), CampaignType.SIMPLE, campaignOwner);
        return address(campaign);
    }

    function createTokenCampaign(address payable campaignOwner, IERC20 token, uint256 goal, uint256 deadline)
        external
        returns (address)
    {
        TokenCampaign campaign = new TokenCampaign(campaignOwner, token, goal, deadline);
        emit CampaignCreated(address(campaign), CampaignType.TOKEN, campaignOwner);
        return address(campaign);
    }

    /// @notice A campaign that accepts ETH and `token`, with the goal in wei.
    function createMixedCampaign(address payable campaignOwner, IERC20 token, uint256 goalWei, uint256 deadline)
        external
        returns (address)
    {
        IPriceOracle oracle = registry.oracleFor(address(token));
        if (address(oracle) == address(0)) revert UnsupportedToken(address(token));
        MixedCampaign campaign = new MixedCampaign(campaignOwner, token, oracle, goalWei, deadline);
        emit CampaignCreated(address(campaign), CampaignType.MIXED, campaignOwner);
        return address(campaign);
    }
}
