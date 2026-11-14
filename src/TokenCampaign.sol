// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignBase} from "./CampaignBase.sol";

/**
 * @title Token Campaign
 * @notice Single ERC-20 campaign. `goal` is in the token's base units.
 *         Donors call `token.approve(campaign, amount)` first, then `donate(amount)`.
 */
contract TokenCampaign is CampaignBase {
    IERC20 public immutable token;
    uint256 public collected;
    mapping(address donor => uint256 amount) public donations;

    constructor(address payable owner_, IERC20 token_, uint256 goal_, uint256 deadline_)
        CampaignBase(owner_, goal_, deadline_)
    {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    function donate(uint256 amount) external nonReentrant acceptingDonations {
        if (amount == 0) revert ZeroDonation();
        uint256 received = _pullToken(token, amount);
        collected += received;
        donations[msg.sender] += received;
        emit DonationReceived(msg.sender, address(token), received);
    }

    function totalRaised() public view override returns (uint256) {
        return collected;
    }

    function _payOut(address payable to) internal override {
        uint256 amount = collected;
        if (amount == 0) revert NothingToClaim();

        collected = 0;
        emit FundsClaimed(to, address(token), amount);
        _sendToken(token, to, amount);
    }

    function _refund(address donor, address payable to) internal override {
        uint256 amount = donations[donor];
        if (amount == 0) revert NothingToRefund();

        donations[donor] = 0;
        collected -= amount;
        emit DonationRefunded(donor, address(token), amount, to);
        _sendToken(token, to, amount);
    }
}
