// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;
// External
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Internal
import "contracts/SimpleCampaign.sol";
import "contracts/TokenCampaign.sol";



/**
 * @title Block Fund
 * @dev Has the ability to create a simple campaign which accepts donations
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts

 */
contract BlockFund {
    enum CampaignType {
        SIMPLE,
        TOKEN
    }

    event createdCampaign(address, CampaignType);
    
    function createSimpleCampaign(address payable campaign_owner, uint256 campaign_goal_wei) public returns (address) {
        SimpleCampaign new_campaign = new SimpleCampaign(campaign_owner, campaign_goal_wei);
        emit createdCampaign(address(new_campaign), CampaignType.SIMPLE);
        return address(new_campaign);
    }

    function createTokenCampaign(address campaign_owner, IERC20 token, uint256 campaign_goal) public returns (address) {
        TokenCampaign new_campaign = new TokenCampaign(campaign_owner, token, campaign_goal);
        emit createdCampaign(address(new_campaign), CampaignType.TOKEN);
        return address(new_campaign);
    }
}