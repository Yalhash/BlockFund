// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SimpleCampaign} from "../src/SimpleCampaign.sol";

contract SimpleCampaignTest is Test {
    SimpleCampaign campaign;

    address payable owner = payable(makeAddr("owner"));
    address donor = makeAddr("donor");
    uint256 constant GOAL = 1 ether;

    function setUp() public {
        campaign = new SimpleCampaign(owner, GOAL);
        vm.deal(donor, 10 ether);
    }

    function test_Donate_HoldsFunds() public {
        vm.prank(donor);
        campaign.donate{value: 0.4 ether}();
        assertEq(address(campaign).balance, 0.4 ether);
    }

    function test_RevertWhen_DonationIsZero() public {
        vm.prank(donor);
        vm.expectRevert(bytes("Must include a donation"));
        campaign.donate{value: 0}();
    }

    function test_Settle_PaysOwnerOnceGoalReached() public {
        vm.prank(donor);
        campaign.donate{value: GOAL}();

        vm.prank(owner);
        campaign.settleCampaign();

        assertEq(owner.balance, GOAL);
        assertEq(address(campaign).balance, 0);
    }

    function test_RevertWhen_SettlingBeforeGoal() public {
        vm.prank(donor);
        campaign.donate{value: GOAL - 1}();

        vm.prank(owner);
        vm.expectRevert(bytes("The campaign goal has not been reached yet."));
        campaign.settleCampaign();
    }

    function test_RevertWhen_NonOwnerSettles() public {
        vm.prank(donor);
        campaign.donate{value: GOAL}();

        vm.prank(donor);
        vm.expectRevert(bytes("This function is only accessible by the owner"));
        campaign.settleCampaign();
    }

    function test_RevertWhen_WithdrawingWhileActive() public {
        vm.prank(donor);
        campaign.donate{value: 1 ether}();

        vm.prank(donor);
        vm.expectRevert(bytes("The campaign must be aborted to allow refunds"));
        campaign.withdrawDonation(payable(donor), 1 ether);
    }

    function testFuzz_AbortThenWithdraw_RefundsDonor(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        uint256 startBalance = donor.balance;

        vm.prank(donor);
        campaign.donate{value: amount}();

        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(donor);
        campaign.withdrawDonation(payable(donor), amount);

        assertEq(donor.balance, startBalance);
        assertEq(address(campaign).balance, 0);
    }

    function test_RevertWhen_WithdrawingMoreThanDonated() public {
        vm.prank(donor);
        campaign.donate{value: 1 ether}();

        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(donor);
        vm.expectRevert(bytes("Message sender has donated less than the requested wei"));
        campaign.withdrawDonation(payable(donor), 1 ether + 1);
    }
}
