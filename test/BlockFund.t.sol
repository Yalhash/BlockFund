// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BlockFund} from "../src/BlockFund.sol";
import {CampaignBase} from "../src/CampaignBase.sol";
import {SimpleCampaign} from "../src/SimpleCampaign.sol";
import {TokenCampaign} from "../src/TokenCampaign.sol";
import {MixedCampaign} from "../src/MixedCampaign.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockOracles.sol";

/// @dev Stand-in for a multisig such as a Safe: a contract that executes calls once its
///      signers have approved them (here simplified to a single controller).
contract MockMultisig {
    address immutable controller;

    constructor() {
        controller = msg.sender;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == controller, "not approved");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

contract BlockFundTest is Test {
    BlockFund fund;
    MockPriceOracle oracle;
    MockERC20 token;

    address fundOwner = makeAddr("fundOwner");
    address payable campaignOwner = payable(makeAddr("campaignOwner"));
    uint256 deadline;

    event CampaignCreated(
        address indexed campaign, BlockFund.CampaignType indexed campaignType, address indexed campaignOwner
    );

    function setUp() public {
        oracle = new MockPriceOracle();
        token = new MockERC20(18);
        oracle.setPrice(address(token), 0.01 ether);
        fund = new BlockFund(fundOwner, IPriceOracle(address(oracle)));
        deadline = block.timestamp + 7 days;
    }

    function test_Constructor() public view {
        assertEq(fund.owner(), fundOwner);
        assertEq(address(fund.oracle()), address(oracle));
    }

    function test_RevertWhen_ConstructedWithZeroOracle() public {
        vm.expectRevert(BlockFund.ZeroAddress.selector);
        new BlockFund(fundOwner, IPriceOracle(address(0)));
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

    function test_CreateMixedCampaign_EmitsMixedType() public {
        vm.expectEmit(false, true, true, false);
        emit CampaignCreated(address(0), BlockFund.CampaignType.MIXED, campaignOwner);
        address campaign = fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 1 ether, deadline);

        MixedCampaign c = MixedCampaign(campaign);
        assertEq(address(c.oracle()), address(oracle));
        assertEq(address(c.token()), address(token));
    }

    function test_RevertWhen_MixedCampaignTokenUnsupported() public {
        MockERC20 other = new MockERC20(18);
        vm.expectRevert(abi.encodeWithSelector(BlockFund.UnsupportedToken.selector, address(other)));
        fund.createMixedCampaign(campaignOwner, IERC20(address(other)), 1 ether, deadline);
    }

    function test_RevertWhen_DeadlineInvalid() public {
        vm.expectRevert(CampaignBase.InvalidDeadline.selector);
        fund.createSimpleCampaign(campaignOwner, 1 ether, block.timestamp);
    }

    function test_SetOracle_OnlyAffectsNewCampaigns() public {
        address before = fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 1 ether, deadline);

        MockPriceOracle newOracle = new MockPriceOracle();
        newOracle.setPrice(address(token), 0.02 ether);
        vm.prank(fundOwner);
        fund.setOracle(IPriceOracle(address(newOracle)));

        address afterChange = fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 1 ether, deadline);
        assertEq(address(MixedCampaign(before).oracle()), address(oracle));
        assertEq(address(MixedCampaign(afterChange).oracle()), address(newOracle));
    }

    // ----- Admin by a multisig, with two-step ownership transfer -----

    function test_TwoStepTransfer_ToMultisig() public {
        MockMultisig multisig = new MockMultisig();

        vm.prank(fundOwner);
        fund.transferOwnership(address(multisig));
        assertEq(fund.owner(), fundOwner, "unchanged until accepted");
        assertEq(fund.pendingOwner(), address(multisig));

        multisig.execute(address(fund), abi.encodeCall(fund.acceptOwnership, ()));
        assertEq(fund.owner(), address(multisig));

        // The multisig can now administer the factory; the old owner can't.
        MockPriceOracle newOracle = new MockPriceOracle();
        multisig.execute(address(fund), abi.encodeCall(fund.setOracle, (IPriceOracle(address(newOracle)))));
        assertEq(address(fund.oracle()), address(newOracle));

        vm.prank(fundOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, fundOwner));
        fund.setOracle(IPriceOracle(address(oracle)));
    }

    function test_RevertWhen_WrongAddressAcceptsOwnership() public {
        address intended = makeAddr("intended");
        address stranger = makeAddr("stranger");

        vm.prank(fundOwner);
        fund.transferOwnership(intended);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.acceptOwnership();
        assertEq(fund.owner(), fundOwner);
    }

    function test_RevertWhen_NonOwnerSetsOracle() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fund.setOracle(IPriceOracle(address(oracle)));
    }
}
