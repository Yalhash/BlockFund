// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BlockFund} from "../src/BlockFund.sol";

/// @notice Deploys the BlockFund factory.
/// Env vars:
///   OWNER        - address that will own the factory
///   POOL_MANAGER - Uniswap v4 PoolManager on the target chain (any address works
///                  locally if you only use Simple/Token campaigns)
///
/// Example:
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account <keystore-name> --broadcast
contract Deploy is Script {
    function run() external returns (BlockFund fund) {
        address owner = vm.envAddress("OWNER");
        address poolManager = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();
        fund = new BlockFund(owner, IPoolManager(poolManager));
        vm.stopBroadcast();

        console.log("BlockFund deployed at", address(fund));
    }
}
