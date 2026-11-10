// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BlockFund} from "../src/BlockFund.sol";
import {ChainlinkTwapOracle} from "../src/oracles/ChainlinkTwapOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Deploys the price oracle and the BlockFund factory.
/// Env vars:
///   OWNER - owner of both contracts (configures price sources, can swap the oracle)
///   WETH  - wrapped ETH on the target chain
///
/// Price sources are added afterwards by OWNER (see README), e.g.
///   cast send $ORACLE "setChainlinkFeed(address,address,uint32,bool)" <token> <feed> 90000 false
///
/// Example:
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast
contract Deploy is Script {
    function run() external returns (ChainlinkTwapOracle oracle, BlockFund fund) {
        address owner = vm.envAddress("OWNER");
        address weth = vm.envAddress("WETH");

        vm.startBroadcast();
        oracle = new ChainlinkTwapOracle(owner, weth);
        fund = new BlockFund(owner, IPriceOracle(address(oracle)));
        vm.stopBroadcast();

        console.log("ChainlinkTwapOracle:", address(oracle));
        console.log("BlockFund:          ", address(fund));
    }
}
