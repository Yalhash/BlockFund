// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BlockFund} from "../src/BlockFund.sol";
import {MixedCampaign} from "../src/MixedCampaign.sol";
import {ChainlinkTwapOracle} from "../src/oracles/ChainlinkTwapOracle.sol";
import {PriceSourceRegistry} from "../src/oracles/PriceSourceRegistry.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IPriceSourceRegistry} from "../src/interfaces/IPriceSourceRegistry.sol";
import {AggregatorV3Interface} from "../src/interfaces/external/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../src/interfaces/external/IUniswapV3Pool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockOracles.sol";

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

contract PriceSourceRegistryTest is Test {
    PriceSourceRegistry registry;
    MockERC20 weth;
    MockERC20 token;

    address admin = makeAddr("admin"); // the multisig in production
    address stranger = makeAddr("stranger");

    function setUp() public {
        weth = new MockERC20(18);
        token = new MockERC20(18);
        registry = new PriceSourceRegistry(admin, address(weth));
    }

    function _chainlink(int256 ethPerToken) internal returns (ChainlinkTwapOracle.ChainlinkParams memory) {
        AggregatorV3Interface feed = AggregatorV3Interface(address(new MockAggregator(18, ethPerToken)));
        return ChainlinkTwapOracle.ChainlinkParams(feed, 1 days, false, AggregatorV3Interface(address(0)), 0);
    }

    function _noTwap() internal pure returns (ChainlinkTwapOracle.TwapParams memory p) {}

    function test_SetSource_DeploysImmutableOracle() public {
        ChainlinkTwapOracle.ChainlinkParams memory p = _chainlink(0.01e18);
        vm.prank(admin);
        IPriceOracle oracle = registry.setSource(address(token), p, _noTwap());

        assertEq(address(registry.oracleFor(address(token))), address(oracle));
        assertEq(ChainlinkTwapOracle(address(oracle)).token(), address(token));
        assertEq(ChainlinkTwapOracle(address(oracle)).weth(), address(weth));
        assertEq(oracle.valueInWei(address(token), 100e18), 1 ether);
    }

    function test_RevertWhen_SourceInvalid() public {
        ChainlinkTwapOracle.ChainlinkParams memory p = _chainlink(0); // no valid answer
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkTwapOracle.FeedUnusable.selector, address(p.feed)));
        registry.setSource(address(token), p, _noTwap());
    }

    function test_RemoveSource() public {
        ChainlinkTwapOracle.ChainlinkParams memory p = _chainlink(0.01e18);
        vm.startPrank(admin);
        registry.setSource(address(token), p, _noTwap());
        registry.removeSource(address(token));
        vm.stopPrank();
        assertEq(address(registry.oracleFor(address(token))), address(0));
    }

    function test_RevertWhen_NonAdminSetsSource() public {
        ChainlinkTwapOracle.ChainlinkParams memory p = _chainlink(0.01e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setSource(address(token), p, _noTwap());
    }

    function test_RevertWhen_NonAdminRemovesSource() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.removeSource(address(token));
    }

    function test_TwoStepOwnershipTransfer() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        registry.transferOwnership(newAdmin);
        assertEq(registry.owner(), admin, "unchanged until accepted");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.acceptOwnership();

        vm.prank(newAdmin);
        registry.acceptOwnership();
        assertEq(registry.owner(), newAdmin);
    }

    function test_MultisigAdmin() public {
        MockMultisig multisig = new MockMultisig();
        vm.prank(admin);
        registry.transferOwnership(address(multisig));
        multisig.execute(address(registry), abi.encodeCall(registry.acceptOwnership, ()));
        assertEq(registry.owner(), address(multisig));

        ChainlinkTwapOracle.ChainlinkParams memory p = _chainlink(0.01e18);
        multisig.execute(address(registry), abi.encodeCall(registry.setSource, (address(token), p, _noTwap())));
        assertTrue(address(registry.oracleFor(address(token))) != address(0));

        // The previous admin has no rights left.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        registry.removeSource(address(token));
    }

    /// @dev The point of this design: the admin changing or removing a token's price source
    ///      has no effect on a campaign that already exists.
    function test_ExistingCampaignKeepsItsPriceSources() public {
        BlockFund fund = new BlockFund(IPriceSourceRegistry(address(registry)));

        ChainlinkTwapOracle.ChainlinkParams memory original = _chainlink(0.01e18); // 0.01 ETH per token
        vm.prank(admin);
        IPriceOracle originalOracle = registry.setSource(address(token), original, _noTwap());

        address payable campaignOwner = payable(makeAddr("campaignOwner"));
        MixedCampaign campaign = MixedCampaign(
            fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 10 ether, block.timestamp + 7 days)
        );

        address donor = makeAddr("donor");
        token.mint(donor, 500e18);
        vm.startPrank(donor);
        token.approve(address(campaign), 500e18);
        campaign.donateToken(500e18);
        vm.stopPrank();
        assertEq(campaign.totalRaised(), 5 ether);

        // Admin repoints the token at a feed claiming it's worth 100x more...
        ChainlinkTwapOracle.ChainlinkParams memory inflated = _chainlink(1e18);
        vm.prank(admin);
        registry.setSource(address(token), inflated, _noTwap());

        // ...but the existing campaign still uses its original oracle and value.
        assertEq(address(campaign.oracle()), address(originalOracle));
        assertEq(campaign.totalRaised(), 5 ether);
        vm.prank(campaignOwner);
        vm.expectRevert(); // GoalNotReached: can't be pushed over the line by the admin
        campaign.settleCampaign();

        // Removing the source doesn't affect it either.
        vm.prank(admin);
        registry.removeSource(address(token));
        assertEq(campaign.totalRaised(), 5 ether);

        // New campaigns follow the registry: now unsupported.
        vm.expectRevert(abi.encodeWithSelector(BlockFund.UnsupportedToken.selector, address(token)));
        fund.createMixedCampaign(campaignOwner, IERC20(address(token)), 10 ether, block.timestamp + 7 days);
    }
}
