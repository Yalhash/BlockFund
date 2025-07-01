// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Token Campaign
 * @dev A simple campaign which accepts donations of an ERC20 token.
 * @custom:dev-run-script ./scripts/deploy_with_ethers.ts
 */



contract TokenCampaign {
    IERC20 public token;
    address owner;
    uint256 goal;
    uint256 collected;
    bool active;
    mapping(address => uint256) refund_mapping;

    event DonationRecieved(address donator, uint256 amount);
    event DonationRefunded(address donator, uint256 amount);

    constructor(address _owner, IERC20 _token, uint256 goal_token) {
        owner = _owner;
        token = IERC20(_token);
        goal = goal_token;
        active = true;
        collected = 0;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "This function is only accessible by the owner");
        _;
    }

    modifier onlyActiveCampaign() {
        require (active, "This function can only be accessed while a campaign is active");
        _;
    }

    // This function expects the contract to have been approved for the amount donated already
    function donate(uint256 amount) public onlyActiveCampaign {
        collected += amount;
        refund_mapping[msg.sender] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "Failed to recieve donation, transfer failed");
        emit DonationRecieved(msg.sender, amount);
    }

    function settleCampaign() public onlyOwner onlyActiveCampaign {
        require(collected >= goal, "The campaign goal has not been reached yet.");
        active = false;
        uint256 amount_to_send = collected;
        collected = 0;
        require(token.transfer(owner, amount_to_send), "Failed to settle campaign, transfer failed");
    }

    function withdrawDonation() public {
        require(!active, "The campaign must be aborted to allow refunds");
        uint256 refund_amount = refund_mapping[msg.sender];
        refund_mapping[msg.sender] = 0;
        collected -= refund_amount;        
        require(token.transfer(msg.sender, refund_amount), "Failed to refund donation, transfer failed");
        emit DonationRefunded(msg.sender, refund_amount);
    }

    // Abort the campaign early, donators can still withdraw their donations
    function abortCampaign() public onlyOwner {
        active = false;
    }
}