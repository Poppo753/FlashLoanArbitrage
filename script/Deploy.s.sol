// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {FlashArbExecutor} from "../contracts/FlashArbExecutor.sol";

contract Deploy is Script {
    function run() external {
        address poolAddress = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
        address owner = vm.envAddress("OWNER");
        address router0 = 0x68b3465833fb72A70ecF484E0b4C990D5;
        address router1 = 0x68b3465833fb72A70ecF484E0b4C990D5;
        uint256 minProfitBps = 50;

        vm.startBroadcast();
        FlashArbExecutor executor = new FlashArbExecutor(
            poolAddress,
            owner,
            minProfitBps,
            router0,
            router1
        );
        vm.stopBroadcast();

        console.log("FlashArbExecutor deployed to:", address(executor));
    }
}
