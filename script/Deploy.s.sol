// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {FlashArbExecutor} from "../contracts/FlashArbExecutor.sol";

contract Deploy is Script {
    function run() external {
        address poolAddress = vm.envAddress("AAVE_POOL_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address router0 = vm.envAddress("ROUTER_0_ADDRESS");
        address router1 = vm.envAddress("ROUTER_1_ADDRESS");
        uint256 minProfitBps = vm.envUint("MIN_PROFIT_BPS");

        vm.startBroadcast();
        FlashArbExecutor executor = new FlashArbExecutor(poolAddress, owner, minProfitBps, router0, router1);
        vm.stopBroadcast();

        console.log("FlashArbExecutor deployed to:", address(executor));
    }
}
