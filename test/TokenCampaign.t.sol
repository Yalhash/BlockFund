// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenCampaign} from "../src/TokenCampaign.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TokenCampaignTest is Test {
    TokenCampaign campaign;
    MockERC20 token;

    address owner = makeAddr("owner");
    address donor = makeAddr("donor");
    uint256 constant GOAL = 1_000e18;

    function setUp() public {
        token = new MockERC20();
        campaign = new TokenCampaign(owner, IERC20(address(token)), GOAL);
        token.mint(donor, 10_000e18);
    }

    function _donate(address from, uint256 amount) internal {
        vm.startPrank(from);
        token.approve(address(campaign), amount);
        campaign.donate(amount);
        vm.stopPrank();
    }

    function test_Donate_TransfersTokens() public {
        _donate(donor, 250e18);
        assertEq(token.balanceOf(address(campaign)), 250e18);
    }

    function test_RevertWhen_DonatingWithoutApproval() public {
        vm.prank(donor);
        vm.expectRevert();
        campaign.donate(1e18);
    }

    function test_Settle_PaysOwnerOnceGoalReached() public {
        _donate(donor, GOAL);

        vm.prank(owner);
        campaign.settleCampaign();

        assertEq(token.balanceOf(owner), GOAL);
        assertEq(token.balanceOf(address(campaign)), 0);
    }

    function test_RevertWhen_SettlingBeforeGoal() public {
        _donate(donor, GOAL - 1);

        vm.prank(owner);
        vm.expectRevert(bytes("The campaign goal has not been reached yet."));
        campaign.settleCampaign();
    }

    function testFuzz_AbortThenWithdraw_RefundsDonor(uint256 amount) public {
        amount = bound(amount, 1, 10_000e18);
        _donate(donor, amount);

        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(donor);
        campaign.withdrawDonation();

        assertEq(token.balanceOf(donor), 10_000e18);
        assertEq(token.balanceOf(address(campaign)), 0);
    }
}
