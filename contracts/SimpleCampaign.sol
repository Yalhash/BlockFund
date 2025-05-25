// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;

/**
 * @title Simple Campaign
 * @dev A simple campaign which accepts donations, and allows withdrawing donations.
 *      Adding an array to store the addresses of the donators and then creating 
 *      a global refund button which could be pressed by the creator is an option,
 *      but this could increase gas costs. Instead I prefer aborting the campaign 
 *      and allowing the users to withdraw their donations, which they can do at any time anyways 
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts

 */
contract SimpleCampaign {
    address payable owner;
    uint256 goal;
    uint256 collected;
    bool active;
    mapping(address => uint256) refund_mapping;

    event DonationRecieved(address donator, uint256 donation_wei);
    event DonationRefunded(address donator, uint256 refund_wei, address refund_address);

    constructor(address payable owner_, uint256 goal_wei) {
        owner = owner_;
        goal = goal_wei;
        active = true;
        collected = 0;
    }

    function donate() public payable {
        require(active, "Campaign is no longer accepting donations");
        require(msg.value > 0, "Must include a donation");
        collected += msg.value;
        refund_mapping[msg.sender] += msg.value;
        emit DonationRecieved(msg.sender, msg.value);
    }

    function settleCampaign() public {
        require(msg.sender == owner, "Only the owner of a campaign can settle it");
        require(collected >= goal, "The campaign has not been reached yet.");
        require(!active, "Campaign is already completed!");
        active = false;
        owner.transfer(collected);
    }

    function withdrawDonation(address payable refund_address, uint256 refund_wei) public {
        require(refund_mapping[msg.sender] >= refund_wei, "Message sender has donated less than the requested wei");
        collected -= refund_wei;
        refund_mapping[msg.sender] -= refund_wei;
        refund_address.transfer(refund_wei);
        emit DonationRefunded(msg.sender, refund_wei, refund_address);
    }

    // Abort the campaign early, donators can still withdraw their donations
    function abortCampaign() public {
        require(msg.sender == owner, "Only the owner of a campaign can abort it");
        active = false;
    }
}