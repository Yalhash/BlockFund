// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title Crypto Campaign
 * @dev Has the ability to create a simple campaign, donate to the campaign, and settle the campaign, only when the goal is reached.
 *      Unfortunately I ran into issues with 
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts

 */
contract CryptoCampaign {
    struct Campaign {
        // address payable owner;
        uint256 goal;
        uint256 collected;
        bool active;
    }
    

    event Debug (uint256 val);

    mapping(address => mapping (uint256 => Campaign)) public campaigns;
    mapping(address => uint256) public campaign_count;
    
    modifier validCampaign(address campaign_owner, uint256 campaign_index) {
        require(campaigns[campaign_owner][campaign_index].active, "Campaign does not exist or is inactive");
        _;
    }
    
    function createCampaign(address payable campaign_owner, uint256 campaign_goal_wei) public returns (uint256) {
        require(msg.sender == campaign_owner, "Can only create a campaign for yourself");
        assert(campaign_goal_wei > 0);
        uint256 campaign_index = campaign_count[campaign_owner]++;
        campaigns[campaign_owner][campaign_index] = Campaign({
            goal: campaign_goal_wei,
            collected: 0,
            // contributions: new Contribution[](0),
            active: true
        });
        emit Debug(campaign_index);
        return campaign_index;
    }

    event FailedToPay (address payee, uint256 amount);


    function settleCampaign(address payable campaign_owner, uint256 campaign_index) validCampaign(campaign_owner, campaign_index) public {
        require(msg.sender == campaign_owner, "Campaign must be settled by the owner");
        // End the campaign, pay the owner
        Campaign storage _campaign = campaigns[campaign_owner][campaign_index];
        require(_campaign.goal <= _campaign.collected, "Campaign has not yet hit its goal");
        _campaign.active = false;
        // This will revert if it fails
        campaign_owner.transfer(_campaign.collected);
        // We will leave the campaign around since it is marked complete now, and it is difficult to manage these campaigns
    }

    function donate(address campaign_owner, uint256 campaign_index) validCampaign(campaign_owner, campaign_index) public payable {
        require(msg.sender != campaign_owner, "Cannot donate to your own campaign");
        require(msg.value > 0, "No amount to donate");

        Campaign storage _campaign = campaigns[campaign_owner][campaign_index];
        _campaign.collected += msg.value;
        // // This is bad, and a reason to have a second contract:
        // uint256 contributorsLength = _campaign.contributions.length;
        // for (uint256 i = 0; i < contributorsLength; ++i) {
        //     if (msg.sender == _campaign.contributions[i].contributor) {
        //         _campaign.contributions[i].amount += msg.value;
        //         return;
        //     }
        // }
        // If we never 
        // _campaign.contributions.push(storage Contribution({contributor: donator_address, amount: msg.value}));        
    }

    // function refundCampaign(uint256 campaign_index) validCampaign(msg.sender, campaign_index) public {
    //     // Destroy the campaign and refund the contributors
    //     Campaign storage _campaign = campaigns[msg.sender][campaign_index];
    //     _campaign.completed = true;
    //     uint256 contributorsLength = _campaign.contributions.length;
    //     for (uint256 i = 0; i < contributorsLength; ++i) {
    //         // For each contributor, refund the amount they donated
    //         Contribution storage contribution = _campaign.contributions[i];
    //         if (contribution.amount > 0) {
    //             bool result = contribution.contributor.send(contribution.amount);
    //             if (!result) {
    //                 emit FailedToRefund(contribution);
    //             }
    //             delete _campaign.contributions[i];
    //         }
    //     }
    //     // We will leave the campaign around, but destroy the large variables
    //     delete _campaign.contributions;
    // }
}