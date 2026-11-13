// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignBase} from "../src/CampaignBase.sol";
import {TokenCampaign} from "../src/TokenCampaign.sol";
import {MockERC20, MockFeeToken, MockNoReturnToken, MockBlacklistToken} from "./mocks/MockERC20.sol";

contract TokenCampaignTest is Test {
    TokenCampaign campaign;
    MockERC20 token;

    address payable owner = payable(makeAddr("owner"));
    address alice = makeAddr("alice");

    uint256 constant GOAL = 1_000e18;
    uint256 constant START = 10_000e18;
    uint256 deadline;

    function setUp() public {
        deadline = block.timestamp + 30 days;
        token = new MockERC20(18);
        campaign = new TokenCampaign(owner, IERC20(address(token)), GOAL, deadline);
        token.mint(alice, START);
    }

    function _donate(uint256 amount) internal {
        vm.startPrank(alice);
        token.approve(address(campaign), amount);
        campaign.donate(amount);
        vm.stopPrank();
    }

    function test_Donate_TransfersTokens() public {
        _donate(250e18);
        assertEq(token.balanceOf(address(campaign)), 250e18);
        assertEq(campaign.donations(alice), 250e18);
    }

    function test_RevertWhen_DonatingWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert();
        campaign.donate(1e18);
    }

    function test_SettleThenClaim_PaysOwner() public {
        _donate(GOAL);
        vm.startPrank(owner);
        campaign.settleCampaign();
        assertEq(token.balanceOf(owner), 0, "settling alone moves nothing");
        campaign.claimFunds(owner);
        vm.stopPrank();

        assertEq(token.balanceOf(owner), GOAL);
        assertEq(token.balanceOf(address(campaign)), 0);
    }

    /// @dev USDC/USDT can blacklist addresses. A blacklisted owner claims to another address.
    function test_BlacklistedOwner_CanClaimElsewhere() public {
        MockBlacklistToken usdcLike = new MockBlacklistToken();
        TokenCampaign c = new TokenCampaign(owner, IERC20(address(usdcLike)), 100e6, deadline);
        usdcLike.mint(alice, 100e6);
        vm.startPrank(alice);
        usdcLike.approve(address(c), 100e6);
        c.donate(100e6);
        vm.stopPrank();

        usdcLike.setBlacklisted(owner, true);
        address payable treasury = payable(makeAddr("treasury"));

        vm.startPrank(owner);
        c.settleCampaign();
        vm.expectRevert(bytes("blacklisted"));
        c.claimFunds(owner);
        c.claimFunds(treasury);
        vm.stopPrank();

        assertEq(usdcLike.balanceOf(treasury), 100e6);
    }

    function test_RevertWhen_SettlingBeforeGoal() public {
        _donate(GOAL - 1);
        vm.prank(owner);
        vm.expectRevert(CampaignBase.GoalNotReached.selector);
        campaign.settleCampaign();
    }

    function testFuzz_RefundAfterMissedDeadline(uint256 amount) public {
        amount = bound(amount, 1, GOAL - 1);
        _donate(amount);
        vm.warp(deadline);

        vm.prank(alice);
        campaign.withdrawDonation(payable(alice));

        assertEq(token.balanceOf(alice), START);
        assertEq(token.balanceOf(address(campaign)), 0);
    }

    function test_FeeOnTransferToken_CreditsAmountReceived() public {
        MockFeeToken feeToken = new MockFeeToken();
        TokenCampaign feeCampaign = new TokenCampaign(owner, IERC20(address(feeToken)), GOAL, deadline);
        feeToken.mint(alice, 100e18);

        vm.startPrank(alice);
        feeToken.approve(address(feeCampaign), 100e18);
        feeCampaign.donate(100e18);
        vm.stopPrank();

        // 1% burned in transit: only 99 arrived, and only 99 is credited.
        assertEq(feeToken.balanceOf(address(feeCampaign)), 99e18);
        assertEq(feeCampaign.donations(alice), 99e18);

        // Refund works (previously it would try to send 100 and revert).
        vm.prank(owner);
        feeCampaign.abortCampaign();
        vm.prank(alice);
        feeCampaign.withdrawDonation(payable(alice));
        assertEq(feeToken.balanceOf(address(feeCampaign)), 0);
    }

    function test_NoReturnValueToken_Works() public {
        MockNoReturnToken usdtLike = new MockNoReturnToken();
        TokenCampaign usdtCampaign = new TokenCampaign(owner, IERC20(address(usdtLike)), 100e6, deadline);
        usdtLike.mint(alice, 100e6);

        vm.startPrank(alice);
        usdtLike.approve(address(usdtCampaign), 100e6);
        usdtCampaign.donate(100e6);
        vm.stopPrank();

        vm.startPrank(owner);
        usdtCampaign.settleCampaign();
        usdtCampaign.claimFunds(owner);
        vm.stopPrank();
        assertEq(usdtLike.balanceOf(owner), 100e6);
    }
}
