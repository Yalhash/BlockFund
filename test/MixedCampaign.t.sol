// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CampaignBase} from "../src/CampaignBase.sol";
import {MixedCampaign} from "../src/MixedCampaign.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockOracles.sol";

contract MixedCampaignTest is Test {
    MixedCampaign campaign;
    MockERC20 token;
    MockPriceOracle oracle;

    address payable owner = payable(makeAddr("owner"));
    address ethDonor = makeAddr("ethDonor");
    address tokenDonor = makeAddr("tokenDonor");

    uint256 constant GOAL = 10 ether;
    uint256 constant TOKEN_PRICE = 0.01 ether; // wei per whole token
    uint256 deadline;

    function setUp() public {
        deadline = block.timestamp + 30 days;
        token = new MockERC20(18);
        oracle = new MockPriceOracle();
        oracle.setPrice(address(token), TOKEN_PRICE);
        campaign = new MixedCampaign(owner, IERC20(address(token)), IPriceOracle(address(oracle)), GOAL, deadline);

        vm.deal(ethDonor, 100 ether);
        token.mint(tokenDonor, 10_000e18);
    }

    function _donateEth(address from, uint256 amount) internal {
        vm.prank(from);
        campaign.donateEth{value: amount}();
    }

    function _donateToken(address from, uint256 amount) internal {
        vm.startPrank(from);
        token.approve(address(campaign), amount);
        campaign.donateToken(amount);
        vm.stopPrank();
    }

    function test_RevertWhen_TokenUnsupported() public {
        MockERC20 other = new MockERC20(18);
        vm.expectRevert(abi.encodeWithSelector(MixedCampaign.UnsupportedToken.selector, address(other)));
        new MixedCampaign(owner, IERC20(address(other)), IPriceOracle(address(oracle)), GOAL, deadline);
    }

    // ----- Bug 1: each donor is refunded in the asset they gave -----

    function test_Refund_EachDonorGetsTheirOwnAsset() public {
        _donateEth(ethDonor, 3 ether);
        _donateToken(tokenDonor, 200e18);

        vm.prank(owner);
        campaign.abortCampaign();

        vm.prank(ethDonor);
        campaign.withdrawDonation(payable(ethDonor));
        vm.prank(tokenDonor);
        campaign.withdrawDonation(payable(tokenDonor));

        assertEq(ethDonor.balance, 100 ether, "ETH donor got their ETH back");
        assertEq(token.balanceOf(ethDonor), 0, "ETH donor got no tokens");
        assertEq(token.balanceOf(tokenDonor), 10_000e18, "token donor got their tokens back");
        assertEq(address(campaign).balance, 0);
        assertEq(token.balanceOf(address(campaign)), 0);
    }

    function testFuzz_Refund_DonorWhoGaveBoth(uint256 ethAmount, uint256 tokenAmount) public {
        ethAmount = bound(ethAmount, 1, 100 ether);
        tokenAmount = bound(tokenAmount, 1, 10_000e18);
        address both = makeAddr("both");
        vm.deal(both, ethAmount);
        token.mint(both, tokenAmount);

        _donateEth(both, ethAmount);
        _donateToken(both, tokenAmount);

        vm.prank(owner);
        campaign.abortCampaign();
        vm.prank(both);
        campaign.withdrawDonation(payable(both));

        assertEq(both.balance, ethAmount);
        assertEq(token.balanceOf(both), tokenAmount);
        assertEq(campaign.ethCollected(), 0);
        assertEq(campaign.tokenCollected(), 0);
    }

    // ----- Bugs 2/3: token value comes from the oracle -----

    function test_TotalRaised_UsesOraclePrice() public {
        _donateEth(ethDonor, 2 ether);
        _donateToken(tokenDonor, 300e18); // 300 * 0.01 = 3 ETH
        assertEq(campaign.totalRaised(), 5 ether);
    }

    function test_SettleThenClaim_PaysOwnerBothAssets() public {
        _donateEth(ethDonor, 4 ether);
        _donateToken(tokenDonor, 600e18); // 6 ETH worth

        vm.startPrank(owner);
        campaign.settleCampaign();
        campaign.claimFunds(owner);
        vm.stopPrank();

        assertEq(owner.balance, 4 ether);
        assertEq(token.balanceOf(owner), 600e18);
        assertEq(campaign.ethCollected(), 0);
        assertEq(campaign.tokenCollected(), 0);
    }

    function test_Claim_BothAssetsToAnotherAddress() public {
        _donateEth(ethDonor, 4 ether);
        _donateToken(tokenDonor, 600e18);
        address payable treasury = payable(makeAddr("treasury"));

        vm.startPrank(owner);
        campaign.settleCampaign();
        campaign.claimFunds(treasury);
        vm.stopPrank();

        assertEq(treasury.balance, 4 ether);
        assertEq(token.balanceOf(treasury), 600e18);
        assertEq(owner.balance, 0);
    }

    function test_Refund_BothAssetsToAnotherAddress() public {
        address both = makeAddr("both");
        address payable newWallet = payable(makeAddr("newWallet"));
        vm.deal(both, 1 ether);
        token.mint(both, 50e18);
        _donateEth(both, 1 ether);
        _donateToken(both, 50e18);

        vm.prank(owner);
        campaign.abortCampaign();
        vm.prank(both);
        campaign.withdrawDonation(newWallet);

        assertEq(newWallet.balance, 1 ether);
        assertEq(token.balanceOf(newWallet), 50e18);
        assertEq(campaign.ethDonations(both), 0);
        assertEq(campaign.tokenDonations(both), 0);
    }

    function test_RevertWhen_TokenValueBelowGoal() public {
        _donateToken(tokenDonor, 999e18); // 9.99 ETH worth
        vm.prank(owner);
        vm.expectRevert(CampaignBase.GoalNotReached.selector);
        campaign.settleCampaign();
    }

    // ----- Oracle outage can't lock donors in -----

    function test_OracleDown_RefundsStillOpenAfterDeadline() public {
        _donateToken(tokenDonor, 2_000e18); // would be 20 ETH worth
        oracle.setShouldRevert(true);
        vm.warp(deadline);

        vm.prank(owner);
        vm.expectRevert(); // can't prove the goal without a price
        campaign.settleCampaign();

        vm.prank(tokenDonor);
        campaign.withdrawDonation(payable(tokenDonor));
        assertEq(token.balanceOf(tokenDonor), 10_000e18);
    }

    // ----- Outcome is final once decided -----

    function test_PriceRiseAfterRefundsOpened_CannotSettle() public {
        _donateToken(tokenDonor, 500e18); // 5 ETH worth, goal missed
        _donateEth(ethDonor, 1 ether);
        vm.warp(deadline);

        vm.prank(ethDonor);
        campaign.withdrawDonation(payable(ethDonor));

        oracle.setPrice(address(token), 1 ether); // tokens now worth 500 ETH
        vm.prank(owner);
        vm.expectRevert(CampaignBase.NotActive.selector);
        campaign.settleCampaign();

        vm.prank(tokenDonor);
        campaign.withdrawDonation(payable(tokenDonor));
        assertEq(token.balanceOf(tokenDonor), 10_000e18);
    }
}
