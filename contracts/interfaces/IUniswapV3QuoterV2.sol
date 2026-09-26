// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV3QuoterV2
 * @notice Minimal Uniswap V3 QuoterV2 interface for off-chain / simulated quoting.
 * @dev Arbitrum QuoterV2: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
 *
 *      IMPORTANT - use QuoterV2, not Quoter V1:
 *        - QuoterV2: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e  (correct, 4-value return)
 *        - Quoter  V1: 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6  (STALE - do not use)
 *      The V1 address still appears in some of the reference repository's config files, but it
 *      is the old Quoter (different selectors, different return shape) and returns different
 *      data. Any address constant in this repo must be QuoterV2.
 *
 *      MUTABILITY: `quoteExactInputSingle` is deliberately declared WITHOUT `view` / `pure`.
 *      The deployed QuoterV2 simulates the swap against live pool state and is `payable`, so it
 *      is a state-reading call: a Solidity `view` declaration would compile but is a lie about
 *      the contract's behaviour, and a `try quoter.quoteExactInputSingle(...)` inside a `view`
 *      function would fail to compile anyway. Quote off-chain with `eth_call` / `callStatic`
 *      (the TS bot does this), or via a `try/catch` in a non-view context.
 */
interface IUniswapV3QuoterV2 {
    /**
     * @notice Returns the amount out for a given exact input single-hop swap.
     * @param tokenIn The token to pay
     * @param tokenOut The token to receive
     * @param amountIn The exact amount of `tokenIn` to swap
     * @param fee The pool fee tier in hundredths of a bip (e.g. 3000 = 0.3%)
     * @param sqrtPriceLimitX96 Price limit as a Q64.96 sqrt price; 0 means no limit
     * @return amountOut The amount of `tokenOut` that would be received
     * @return sqrtPriceX96After The sqrt price of the pool after the simulated swap
     * @return initializedTicksCrossed The number of initialized ticks crossed by the swap
     * @return gasEstimate The gas estimate for the swap
     */
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint160 sqrtPriceLimitX96
    )
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    /**
     * @notice Returns the amount out for a given exact input multi-hop swap.
     * @param path The encoded multi-hop path: token, fee, token, fee, token ...
     * @param amountIn The exact amount of the first token in `path` to swap
     * @return amountOut The amount of the last token in `path` that would be received
     */
    function quoteExactInput(bytes calldata path, uint256 amountIn) external returns (uint256 amountOut);
}
