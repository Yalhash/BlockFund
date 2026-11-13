// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {SimpleCampaign} from "./SimpleCampaign.sol";
import {TokenCampaign} from "./TokenCampaign.sol";
import {MixedCampaign} from "./MixedCampaign.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title Block Fund
 * @notice Factory that deploys one contract per campaign. Anyone can create a campaign.
 * @dev Mixed campaigns are limited to tokens the price oracle supports. Each mixed campaign
 *      keeps the oracle it was created with; `setOracle` only affects new campaigns.
 *
 *      Admin: intended to be owned by a multisig (e.g. a Safe). Ownership transfers are
 *      two-step: `transferOwnership(new)`, then the new owner calls `acceptOwnership()`,
 *      so a typo'd address can't take over admin rights.
 */
contract BlockFund is Ownable2Step {
    enum CampaignType {
        SIMPLE,
        TOKEN,
        MIXED
    }

    IPriceOracle public oracle;

    event CampaignCreated(address indexed campaign, CampaignType indexed campaignType, address indexed campaignOwner);
    event OracleChanged(address oracle);

    error ZeroAddress();
    error UnsupportedToken(address token);

    constructor(address initialOwner, IPriceOracle oracle_) Ownable(initialOwner) {
        _setOracle(oracle_);
    }

    function setOracle(IPriceOracle oracle_) external onlyOwner {
        _setOracle(oracle_);
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
        if (!oracle.isSupported(address(token))) revert UnsupportedToken(address(token));
        MixedCampaign campaign = new MixedCampaign(campaignOwner, token, oracle, goalWei, deadline);
        emit CampaignCreated(address(campaign), CampaignType.MIXED, campaignOwner);
        return address(campaign);
    }

    function _setOracle(IPriceOracle oracle_) internal {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleChanged(address(oracle_));
    }
}
