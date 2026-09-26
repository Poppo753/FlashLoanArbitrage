// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Constants {
    address constant MOCK_POOL = address(0x00000000000000000000000000000000000001);
    address constant MOCK_ROUTER0 = address(0x00000000000000000000000000000000000002);
    address constant MOCK_ROUTER1 = address(0x00000000000000000000000000000000000003);
    address constant MOCK_RECEIVER = address(0x00000000000000000000000000000000000004);

    address constant TOKEN_A = address(0x0000000000000000000000000000000000000A);
    address constant TOKEN_B = address(0x0000000000000000000000000000000000000B);
    address constant TOKEN_C = address(0x0000000000000000000000000000000000000C);

    uint256 constant ONE_ETH = 1 ether;
    uint256 constant ONE_HUNDRED_THOUSAND_USDC = 100_000 * 1e6;
    uint256 constant ONE_MILLION_TOKENS = 1_000_000 * 1e18;
    uint256 constant TEN_THOUSAND_TOKENS = 10_000 * 1e18;
    uint256 constant FIVE_HUNDRED_TOKENS = 500 * 1e18;

    uint256 constant FIVE_BPS_PREMIUM = 50;
    uint256 constant THREE_BPS_SWAP_FEE = 30;
    uint256 constant MIN_PROFIT_BPS = 50;
    uint256 constant ZERO_PROFIT_BPS = 0;
    uint256 constant HUNDRED_PERCENT = 10000;

    bytes constant VALID_PARAMS = abi.encode(address(TOKEN_B), address(TOKEN_C), uint256(0));
}
