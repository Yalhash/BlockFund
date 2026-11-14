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
        campaign.withdrawDonation(payable(address(this)));
    }

    receive() external payable {
        campaign.withdrawDonation(payable(address(this)));
    }
}

/// @dev A contract with no receive()/fallback, so it can't accept ETH. Stands in for a
///      DAO, vesting contract, etc. used as a campaign owner or donor.
contract EthRejectingAccount {
    function settle(SimpleCampaign c) external {
        c.settleCampaign();
    }

    function claim(SimpleCampaign c, address payable to) external {
        c.claimFunds(to);
    }

    function donate(SimpleCampaign c) external payable {
        c.donate{value: msg.value}();
    }

    function withdraw(SimpleCampaign c, address payable to) external {
        c.withdrawDonation(to);
    }
}

/// @dev Covers the shared CampaignBase lifecycle (deadline, settle, claim, abort, refunds).
contract SimpleCampaignTest is Test {
    SimpleCampaign campaign;

    address payable owner = payable(makeAddr("owner"));
    address payable treasury = payable(makeAddr("treasury"));
    address payable alice = payable(makeAddr("alice"));
    address payable bob = payable(makeAddr("bob"));
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

    function _withdraw(address payable donor) internal {
        vm.prank(donor);
        campaign.withdrawDonation(donor);
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

    function test_Settle_RecordsOutcomeWithoutMovingFunds() public {
        _donate(alice, GOAL);
        vm.prank(owner);
        campaign.settleCampaign();

        assertEq(uint8(campaign.state()), uint8(CampaignBase.State.Settled));
        assertEq(address(campaign).balance, GOAL, "funds wait to be claimed");
        assertEq(owner.balance, 0);
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
        assertEq(uint8(campaign.state()), uint8(CampaignBase.State.Settled));
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

    // ----- claiming -----

    function test_Claim_ToOwnAddress() public {
        _donate(alice, GOAL);
        vm.startPrank(owner);
        campaign.settleCampaign();
        campaign.claimFunds(owner);
        vm.stopPrank();

        assertEq(owner.balance, GOAL);
        assertEq(address(campaign).balance, 0);
    }

    function test_Claim_ToAnotherAddress() public {
        _donate(alice, GOAL);
        vm.startPrank(owner);
        campaign.settleCampaign();
        campaign.claimFunds(treasury);
        vm.stopPrank();

        assertEq(treasury.balance, GOAL);
        assertEq(owner.balance, 0);
    }

    function test_RevertWhen_NonOwnerClaims() public {
        _donate(alice, GOAL);
        vm.prank(owner);
        campaign.settleCampaign();

        vm.prank(stranger);
        vm.expectRevert(CampaignBase.OnlyOwner.selector);
        campaign.claimFunds(payable(stranger));
    }

    function test_RevertWhen_ClaimingBeforeSettle() public {
        _donate(alice, GOAL);
        vm.prank(owner);
        vm.expectRevert(CampaignBase.NotSettled.selector);
        campaign.claimFunds(owner);
    }

    function test_RevertWhen_ClaimingTwice() public {
        _donate(alice, GOAL);
        vm.startPrank(owner);
        campaign.settleCampaign();
        campaign.claimFunds(owner);
        vm.expectRevert(CampaignBase.NothingToClaim.selector);
        campaign.claimFunds(owner);
        vm.stopPrank();
    }

    function test_RevertWhen_ClaimingToZeroAddress() public {
        _donate(alice, GOAL);
        vm.startPrank(owner);
        campaign.settleCampaign();
        vm.expectRevert(CampaignBase.ZeroAddress.selector);
        campaign.claimFunds(payable(address(0)));
        vm.stopPrank();
    }

    /// @dev The case that could previously lock funds forever: an owner contract that
    ///      can't receive ETH. It settles, then claims to an address that can.
    function test_OwnerContractThatRejectsEth_CanClaimElsewhere() public {
        EthRejectingAccount ownerContract = new EthRejectingAccount();
        SimpleCampaign c = new SimpleCampaign(payable(address(ownerContract)), GOAL, deadline);
        vm.prank(alice);
        c.donate{value: GOAL}();

        ownerContract.settle(c);

        // Sending to itself fails...
        vm.expectRevert(CampaignBase.EthTransferFailed.selector);
        ownerContract.claim(c, payable(address(ownerContract)));

        // ...but the funds aren't stuck: it picks another address.
        ownerContract.claim(c, treasury);
        assertEq(treasury.balance, GOAL);
    }

    // ----- refunds -----

    function test_RevertWhen_WithdrawingBeforeDeadline() public {
        _donate(alice, 0.5 ether);
        vm.prank(alice);
        vm.expectRevert(CampaignBase.RefundsNotOpen.selector);
        campaign.withdrawDonation(alice);
    }

    function test_Withdraw_OpensRefundsAfterMissedDeadline() public {
        _donate(alice, 0.5 ether);
        vm.warp(deadline);

        _withdraw(alice);

        assertEq(alice.balance, 10 ether);
        assertEq(uint8(campaign.state()), uint8(CampaignBase.State.Refunding));
    }

    function test_Withdraw_ToAnotherAddress() public {
        _donate(alice, 0.5 ether);
        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(alice);
        campaign.withdrawDonation(bob);

        assertEq(bob.balance, 10.5 ether);
        assertEq(alice.balance, 9.5 ether);
        assertEq(campaign.donations(alice), 0);
    }

    function test_RevertWhen_WithdrawingToZeroAddress() public {
        _donate(alice, 0.5 ether);
        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(alice);
        vm.expectRevert(CampaignBase.ZeroAddress.selector);
        campaign.withdrawDonation(payable(address(0)));
    }

    function test_DonorContractThatRejectsEth_CanWithdrawElsewhere() public {
        EthRejectingAccount donorContract = new EthRejectingAccount();
        donorContract.donate{value: 1 ether}(campaign);
        vm.prank(owner);
        campaign.abortCampaign();

        donorContract.withdraw(campaign, treasury);
        assertEq(treasury.balance, 1 ether);
    }

    function test_RevertWhen_StrangerWithdrawsSomeoneElsesDonation() public {
        _donate(alice, 0.5 ether);
        vm.prank(owner);
        campaign.abortCampaign();

        // A stranger can only withdraw their own (zero) donation, wherever they send it.
        vm.prank(stranger);
        vm.expectRevert(CampaignBase.NothingToRefund.selector);
        campaign.withdrawDonation(payable(stranger));
        assertEq(campaign.donations(alice), 0.5 ether);
    }

    function test_RevertWhen_WithdrawingAfterDeadlineWhenGoalReached() public {
        _donate(alice, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(CampaignBase.RefundsNotOpen.selector);
        campaign.withdrawDonation(alice);
    }

    function test_RevertWhen_SettlingAfterRefundsOpened() public {
        _donate(alice, 0.5 ether);
        vm.warp(deadline);
        _withdraw(alice);

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
        campaign.withdrawDonation(alice);
    }

    function test_RevertWhen_ClaimingAfterAbort() public {
        _donate(alice, GOAL);
        vm.startPrank(owner);
        campaign.abortCampaign();
        vm.expectRevert(CampaignBase.NotSettled.selector);
        campaign.claimFunds(owner);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawingTwice() public {
        _donate(alice, 0.5 ether);
        vm.prank(owner);
        campaign.abortCampaign();

        vm.startPrank(alice);
        campaign.withdrawDonation(alice);
        vm.expectRevert(CampaignBase.NothingToRefund.selector);
        campaign.withdrawDonation(alice);
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

        _withdraw(alice);
        _withdraw(bob);

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
        _withdraw(alice);
        assertEq(alice.balance, 10 ether);
    }
}
