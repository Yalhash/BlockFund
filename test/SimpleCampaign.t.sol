// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CampaignBase} from "../src/CampaignBase.sol";
import {SimpleCampaign} from "../src/SimpleCampaign.sol";

/// @dev Tries to re-enter withdrawDonation when it receives ETH.
contract ReentrantDonor {
    SimpleCampaign immutable campaign;

    constructor(SimpleCampaign campaign_) {
        campaign = campaign_;
    }

    function donate() external payable {
        campaign.donate{value: msg.value}();
    }

    function withdraw() external {
        campaign.withdrawDonation();
    }

    receive() external payable {
        campaign.withdrawDonation();
    }
}

/// @dev Covers the shared CampaignBase lifecycle (deadline, settle, abort, refunds).
contract SimpleCampaignTest is Test {
    SimpleCampaign campaign;

    address payable owner = payable(makeAddr("owner"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    uint256 constant GOAL = 1 ether;
    uint256 deadline;

    function setUp() public {
        deadline = block.timestamp + 30 days;
        campaign = new SimpleCampaign(owner, GOAL, deadline);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _donate(address from, uint256 amount) internal {
        vm.prank(from);
        campaign.donate{value: amount}();
    }

    // ----- constructor -----

    function test_RevertWhen_ConstructedWithZeroOwner() public {
        vm.expectRevert(CampaignBase.ZeroAddress.selector);
        new SimpleCampaign(payable(address(0)), GOAL, deadline);
    }

    function test_RevertWhen_ConstructedWithZeroGoal() public {
        vm.expectRevert(CampaignBase.ZeroGoal.selector);
        new SimpleCampaign(owner, 0, deadline);
    }

    function test_RevertWhen_DeadlineNotInFuture() public {
        vm.expectRevert(CampaignBase.InvalidDeadline.selector);
        new SimpleCampaign(owner, GOAL, block.timestamp);
    }

    function test_RevertWhen_DeadlineTooFar() public {
        uint256 tooFar = block.timestamp + campaign.MAX_DURATION() + 1;
        vm.expectRevert(CampaignBase.InvalidDeadline.selector);
        new SimpleCampaign(owner, GOAL, tooFar);
    }

    // ----- donations -----

    function test_Donate_TracksDonor() public {
        _donate(alice, 0.4 ether);
        assertEq(campaign.donations(alice), 0.4 ether);
        assertEq(campaign.totalRaised(), 0.4 ether);
        assertEq(address(campaign).balance, 0.4 ether);
    }

    function test_RevertWhen_DonationIsZero() public {
        vm.prank(alice);
        vm.expectRevert(CampaignBase.ZeroDonation.selector);
        campaign.donate{value: 0}();
    }

    function test_RevertWhen_DonatingAfterDeadline() public {
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(CampaignBase.DonationsClosed.selector);
        campaign.donate{value: 1 ether}();
    }

    function test_RevertWhen_DonatingAfterAbort() public {
        vm.prank(owner);
        campaign.abortCampaign();
        vm.prank(alice);
        vm.expectRevert(CampaignBase.DonationsClosed.selector);
        campaign.donate{value: 1 ether}();
    }

    // ----- settling -----

    function test_Settle_OwnerCanSettleEarlyOnceGoalReached() public {
        _donate(alice, GOAL);
        vm.prank(owner);
        campaign.settleCampaign();

        assertEq(owner.balance, GOAL);
        assertEq(address(campaign).balance, 0);
        assertEq(uint8(campaign.state()), uint8(CampaignBase.State.Settled));
    }

    function test_RevertWhen_StrangerSettlesBeforeDeadline() public {
        _donate(alice, GOAL);
        vm.prank(stranger);
        vm.expectRevert(CampaignBase.OnlyOwnerBeforeDeadline.selector);
        campaign.settleCampaign();
    }

    function test_Settle_AnyoneCanSettleAfterDeadline() public {
        _donate(alice, GOAL);
        vm.warp(deadline);
        vm.prank(stranger);
        campaign.settleCampaign();
        assertEq(owner.balance, GOAL);
    }

    function test_RevertWhen_SettlingBeforeGoal() public {
        _donate(alice, GOAL - 1);
        vm.prank(owner);
        vm.expectRevert(CampaignBase.GoalNotReached.selector);
        campaign.settleCampaign();
    }

    function test_RevertWhen_SettlingTwice() public {
        _donate(alice, GOAL);
        vm.prank(owner);
        campaign.settleCampaign();
        vm.prank(owner);
        vm.expectRevert(CampaignBase.NotActive.selector);
        campaign.settleCampaign();
    }

    // ----- refunds -----

    function test_RevertWhen_WithdrawingBeforeDeadline() public {
        _donate(alice, 0.5 ether);
        vm.prank(alice);
        vm.expectRevert(CampaignBase.RefundsNotOpen.selector);
        campaign.withdrawDonation();
    }

    function test_Withdraw_OpensRefundsAfterMissedDeadline() public {
        _donate(alice, 0.5 ether);
        vm.warp(deadline);

        vm.prank(alice);
        campaign.withdrawDonation();

        assertEq(alice.balance, 10 ether);
        assertEq(uint8(campaign.state()), uint8(CampaignBase.State.Refunding));
    }

    function test_RevertWhen_WithdrawingAfterDeadlineWhenGoalReached() public {
        _donate(alice, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(CampaignBase.RefundsNotOpen.selector);
        campaign.withdrawDonation();
    }

    function test_RevertWhen_SettlingAfterRefundsOpened() public {
        _donate(alice, 0.5 ether);
        vm.warp(deadline);
        vm.prank(alice);
        campaign.withdrawDonation();

        vm.prank(owner);
        vm.expectRevert(CampaignBase.NotActive.selector);
        campaign.settleCampaign();
    }

    function test_RevertWhen_WithdrawingAfterSettle() public {
        _donate(alice, GOAL);
        vm.prank(owner);
        campaign.settleCampaign();
        vm.prank(alice);
        vm.expectRevert(CampaignBase.RefundsNotOpen.selector);
        campaign.withdrawDonation();
    }

    function test_RevertWhen_WithdrawingTwice() public {
        _donate(alice, 0.5 ether);
        vm.prank(owner);
        campaign.abortCampaign();

        vm.startPrank(alice);
        campaign.withdrawDonation();
        vm.expectRevert(CampaignBase.NothingToRefund.selector);
        campaign.withdrawDonation();
        vm.stopPrank();
    }

    function test_RevertWhen_NonOwnerAborts() public {
        vm.prank(stranger);
        vm.expectRevert(CampaignBase.OnlyOwner.selector);
        campaign.abortCampaign();
    }

    function test_RevertWhen_AbortingAfterSettle() public {
        _donate(alice, GOAL);
        vm.startPrank(owner);
        campaign.settleCampaign();
        vm.expectRevert(CampaignBase.NotActive.selector);
        campaign.abortCampaign();
        vm.stopPrank();
    }

    function testFuzz_AbortThenEveryoneIsRefunded(uint256 a, uint256 b) public {
        a = bound(a, 1, 10 ether);
        b = bound(b, 1, 10 ether);
        _donate(alice, a);
        _donate(bob, b);

        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(alice);
        campaign.withdrawDonation();
        vm.prank(bob);
        campaign.withdrawDonation();

        assertEq(alice.balance, 10 ether);
        assertEq(bob.balance, 10 ether);
        assertEq(address(campaign).balance, 0);
        assertEq(campaign.totalRaised(), 0);
    }

    function test_Reentrancy_IsBlocked() public {
        ReentrantDonor attacker = new ReentrantDonor(campaign);
        attacker.donate{value: 1 ether}();
        _donate(alice, 1 ether);

        vm.prank(owner);
        campaign.abortCampaign();

        // The attacker's receive() re-enters, which reverts, so the ETH send fails.
        vm.expectRevert(CampaignBase.EthTransferFailed.selector);
        attacker.withdraw();

        // Alice's funds are untouched.
        vm.prank(alice);
        campaign.withdrawDonation();
        assertEq(alice.balance, 10 ether);
    }
}
