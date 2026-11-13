// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BlockFund} from "../src/BlockFund.sol";
import {ChainlinkTwapOracle} from "../src/oracles/ChainlinkTwapOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Deploys the price oracle and the BlockFund factory, both owned by OWNER.
/// Env vars:
///   OWNER - admin of both contracts. Must be a deployed multisig (e.g. a Safe) on any
///           chain except a local anvil chain (chain id 31337), where a plain wallet is fine.
///   WETH  - wrapped ETH on the target chain
///
/// Price sources are then added by OWNER through the Safe (see README).
///
/// Example:
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast
contract Deploy is Script {
    uint256 constant LOCAL_CHAIN_ID = 31337;

    function run() external returns (ChainlinkTwapOracle oracle, BlockFund fund) {
        address owner = vm.envAddress("OWNER");
        address weth = vm.envAddress("WETH");

        if (block.chainid != LOCAL_CHAIN_ID) {
            require(
                owner.code.length > 0,
                "OWNER has no contract code: use your Safe's address (and check it's deployed on this chain)"
            );
        }

        vm.startBroadcast();
        oracle = new ChainlinkTwapOracle(owner, weth);
        fund = new BlockFund(owner, IPriceOracle(address(oracle)));
        vm.stopBroadcast();

        console.log("Owner (multisig):   ", owner);
        console.log("ChainlinkTwapOracle:", address(oracle));
        console.log("BlockFund:          ", address(fund));
    }
}
