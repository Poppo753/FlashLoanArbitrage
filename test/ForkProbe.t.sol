// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";

/// @dev Throwaway probe: reports what the fork environment actually looks like.
contract ForkProbeTest is Test {
    function test_Probe() public view {
        console.log("block.number", block.number);
        console.log("block.timestamp", block.timestamp);
        console.log("chainid", block.chainid);
        console.log("activeFork", vm.activeFork());
        console.log("env FORK_ENABLED", vm.envOr("FORK_ENABLED", uint256(777)));
        console.log("balancer code", BALANCER.code.length);
        console.log("WETH code", WETH.code.length);
    }

    address constant BALANCER = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
}
