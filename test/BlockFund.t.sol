// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlockFund} from "../src/BlockFund.sol";
import {CampaignBase} from "../src/CampaignBase.sol";
import {SimpleCampaign} from "../src/SimpleCampaign.sol";
import {TokenCampaign} from "../src/TokenCampaign.sol";
import {MixedCampaign} from "../src/MixedCampaign.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IPriceSourceRegistry} from "../src/interfaces/IPriceSourceRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle, MockRegistry} from "./mocks/MockOracles.sol";

contract BlockFundTest is Test {
    BlockFund fund;
    MockRegistry registry;
    MockPriceOracle oracle;
    MockERC20 token;

    address payable campaignOwner = payable(makeAddr("campaignOwner"));
    uint256 deadline;

    event CampaignCreated(
        address indexed campaign, BlockFund.CampaignType indexed campaignType, address indexed campaignOwner
    );

    function setUp() public {
        token = new MockERC20(18);
        oracle = new MockPriceOracle();
        oracle.setPrice(address(token), 0.01 ether);
        registry = new MockRegistry();
        registry.set(address(token), IPriceOracle(address(oracle)));
        fund = new BlockFund(IPriceSourceRegistry(address(registry)));
        deadline = block.timestamp + 7 days;
    }

    function test_Constructor() public view {
        assertEq(address(fund.registry()), address(registry));
    }

    function test_RevertWhen_ConstructedWithZeroRegistry() public {
        vm.expectRevert(BlockFund.ZeroAddress.selector);
        new BlockFund(IPriceSourceRegistry(address(0)));
    }

    function test_CreateSimpleCampaign() public {
        vm.recordLogs();
        address campaign = fund.createSimpleCampaign(campaignOwner, 1 ether, deadline);

        SimpleCampaign c = SimpleCampaign(campaign);
        assertEq(c.owner(), campaignOwner);
        assertEq(c.goal(), 1 ether);
        assertEq(c.deadline(), deadline);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory created = logs[logs.length - 1];
        assertEq(created.topics[0], CampaignCreated.selector);
        assertEq(address(uint160(uint256(created.topics[1]))), campaign);
        assertEq(uint256(created.topics[2]), uint256(BlockFund.CampaignType.SIMPLE));
        assertEq(address(uint160(uint256(created.topics[3]))), campaignOwner);
    }

    function test_CreateTokenCampaign() public {
        address campaign = fund.createTokenCampaign(campaignOwner, IERC20(address(token)), 100e18, deadline);
        assertEq(address(TokenCampaign(campaign).token()), address(token));
    }

    function test_CreateMixedCampaign_UsesRegistryOracle() public {
        vm.expectEmit(false, true, true, false);
        emit CampaignCreated(address(0), BlockFund.CampaignType.MIXED, campaignOwner);
        address campaign = fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 1 ether, deadline);

        MixedCampaign c = MixedCampaign(campaign);
        assertEq(address(c.oracle()), address(oracle));
        assertEq(address(c.token()), address(token));
    }

    function test_RevertWhen_MixedCampaignTokenNotInRegistry() public {
        MockERC20 other = new MockERC20(18);
        vm.expectRevert(abi.encodeWithSelector(BlockFund.UnsupportedToken.selector, address(other)));
        fund.createMixedCampaign(campaignOwner, IERC20(address(other)), 1 ether, deadline);
    }

    function test_RevertWhen_DeadlineInvalid() public {
        vm.expectRevert(CampaignBase.InvalidDeadline.selector);
        fund.createSimpleCampaign(campaignOwner, 1 ether, block.timestamp);
    }

    function test_RegistryChange_OnlyAffectsNewCampaigns() public {
        address existing = fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 1 ether, deadline);

        MockPriceOracle newOracle = new MockPriceOracle();
        newOracle.setPrice(address(token), 0.02 ether);
        registry.set(address(token), IPriceOracle(address(newOracle)));

        address created = fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 1 ether, deadline);
        assertEq(address(MixedCampaign(existing).oracle()), address(oracle));
        assertEq(address(MixedCampaign(created).oracle()), address(newOracle));
    }
}
