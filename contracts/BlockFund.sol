// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;
import "contracts/SimpleCampaign.sol";

/**
 * @title Block Fund
 * @dev Has the ability to create a simple campaign which accepts donations
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts

 */
contract BlockFund {


    event createdCampaign(SimpleCampaign new_campaign);
    
    function createCampaign(address payable campaign_owner, uint256 campaign_goal_wei) public returns (address) {
        SimpleCampaign new_campaign = new SimpleCampaign(campaign_owner, campaign_goal_wei);
        emit createdCampaign(new_campaign);
        return address(new_campaign);
    }
}