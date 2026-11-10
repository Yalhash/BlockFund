// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BlockFund} from "../src/BlockFund.sol";
import {SimpleCampaign} from "../src/SimpleCampaign.sol";
import {TokenCampaign} from "../src/TokenCampaign.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Unit tests for the factory. MixedCampaign needs a real Uniswap v4 pool,
///      so it will be covered by fork tests (see README).
contract BlockFundTest is Test {
    BlockFund fund;

    address fundOwner = makeAddr("fundOwner");
    address payable campaignOwner = payable(makeAddr("campaignOwner"));
    // No pool manager is needed for Simple/Token campaigns; any address works here.
    IPoolManager poolManager = IPoolManager(makeAddr("poolManager"));

    function setUp() public {
        fund = new BlockFund(fundOwner, poolManager);
    }

    function test_Constructor_SetsOwnerAndPoolManager() public view {
        assertEq(fund.owner(), fundOwner);
        assertEq(address(fund.pool_manager()), address(poolManager));
    }

    function test_CreateSimpleCampaign_DeploysContract() public {
        address campaign = fund.createSimpleCampaign(campaignOwner, 1 ether);
        assertGt(campaign.code.length, 0);

        // The new campaign accepts donations.
        vm.deal(address(this), 1 ether);
        SimpleCampaign(campaign).donate{value: 1 ether}();
        assertEq(campaign.balance, 1 ether);
    }

    function test_CreateTokenCampaign_DeploysContract() public {
        MockERC20 token = new MockERC20();
        address campaign = fund.createTokenCampaign(campaignOwner, IERC20(address(token)), 100e18);
        assertGt(campaign.code.length, 0);
        assertEq(address(TokenCampaign(campaign).token()), address(token));
    }

    function test_RevertWhen_MixedCampaignTokenNotRegistered() public {
        vm.expectRevert(bytes("Token is not supported!"));
        fund.createMixedCampaign(campaignOwner, makeAddr("token"), 1 ether);
    }

    function test_RevertWhen_NonOwnerAddsTokenPool() public {
        vm.expectRevert(bytes("This function is only accessible by the owner"));
        fund.addTokenPool(PoolId.wrap(bytes32(0)), Currency.wrap(makeAddr("token")));
    }

    function test_ChangeOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(fundOwner);
        fund.changeOwner(newOwner);
        assertEq(fund.owner(), newOwner);
    }

    function test_RevertWhen_NonOwnerChangesOwner() public {
        vm.expectRevert(bytes("This function is only accessible by the owner"));
        fund.changeOwner(address(this));
    }
}
