// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {CampaignBase} from "./CampaignBase.sol";

/**
 * @title Simple Campaign
 * @notice ETH-only campaign. `goal` is in wei.
 */
contract SimpleCampaign is CampaignBase {
    uint256 public collected;
    mapping(address donor => uint256 amount) public donations;

    constructor(address payable owner_, uint256 goalWei, uint256 deadline_) CampaignBase(owner_, goalWei, deadline_) {}

    function donate() external payable nonReentrant acceptingDonations {
        if (msg.value == 0) revert ZeroDonation();
        collected += msg.value;
        donations[msg.sender] += msg.value;
        emit DonationReceived(msg.sender, ETH, msg.value);
    }

    function totalRaised() public view override returns (uint256) {
        return collected;
    }

    function _payOwner() internal override {
        uint256 amount = collected;
        collected = 0;
        _sendEth(owner, amount);
    }

    function _refund(address payable donor) internal override {
        uint256 amount = donations[donor];
        if (amount == 0) revert NothingToRefund();

        donations[donor] = 0;
        collected -= amount;
        emit DonationRefunded(donor, ETH, amount);
        _sendEth(donor, amount);
    }
}
