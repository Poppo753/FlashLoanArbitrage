// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ArbitragePlugin} from "../contracts/ArbitragePlugin.sol";
import {FlashLoanService} from "../contracts/services/FlashLoanService.sol";

/**
 * @title Deploy
 * @notice Deploys the two-contract arbitrage system on Arbitrum.
 *
 * @dev Deployment order is forced by the authorization design (decision D13):
 *      the flash loan service wants the plugin address in its constructor,
 *      while the plugin needs the service address to recognize the callback.
 *      So: plugin first (with no service), then the service pointing at the
 *      plugin, then a single `initialize` call to wire them together.
 *
 *      Required environment variables:
 *        - BASE_TOKEN_ADDRESS   base token to borrow (USDC on Arbitrum)
 *        - QUOTE_TOKEN_ADDRESS  intermediate token (WETH on Arbitrum)
 *        - VENUE_A_ROUTER       Uniswap V2 compatible router
 *        - VENUE_B_ROUTER       Uniswap V3 SwapRouter
 *        - MIN_PROFIT           minimum profit in base token wei (optional, default 0)
 *        - MAX_SLIPPAGE_BPS     slippage budget in bps (optional, default 50)
 *        - DEADLINE_WINDOW      deadline window in seconds (optional, default 60)
 *
 *      `forge script script/Deploy.s.sol --rpc-url arbitrum --broadcast`
 */
contract Deploy is Script {
    function run() external {
        address baseToken = vm.envAddress("BASE_TOKEN_ADDRESS");
        address quoteToken = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        address venueA = vm.envAddress("VENUE_A_ROUTER");
        address venueB = vm.envAddress("VENUE_B_ROUTER");

        uint256 minProfit = vm.envOr("MIN_PROFIT", uint256(0));
        uint256 maxSlippageBps = vm.envOr("MAX_SLIPPAGE_BPS", uint256(50));
        uint256 deadlineWindow = vm.envOr("DEADLINE_WINDOW", uint256(60));

        vm.startBroadcast();

        // 1. Plugin first: the service needs its address, not the other way round.
        ArbitragePlugin plugin =
            new ArbitragePlugin(baseToken, quoteToken, venueA, venueB, maxSlippageBps, deadlineWindow);

        // 2. Service authorizes exactly this plugin.
        FlashLoanService service = new FlashLoanService(address(plugin));

        // 3. Wire the plugin to the service and arm the profit floor.
        plugin.initialize(address(service));
        if (minProfit > 0) {
            plugin.setMinProfit(minProfit);
        }

        vm.stopBroadcast();

        console.log("ArbitragePlugin deployed to:", address(plugin));
        console.log("FlashLoanService deployed to:", address(service));
        console.log("Base token:", baseToken);
        console.log("Quote token:", quoteToken);
        console.log("Min profit (base token wei):", minProfit);
    }
}
