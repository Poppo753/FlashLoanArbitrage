// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV3Router
 * @notice Interface for the Uniswap V3 SwapRouter (the `SwapRouter`, not the `Router02` multicall).
 * @dev Arbitrum SwapRouter: 0xE592427A0AEce92De3Edee1F18E0157C05861564
 *
 *      Struct field order matches the deployed contract exactly, so a struct literal can be
 *      passed straight through from the flash-loan callback. The file is intentionally
 *      self-contained: it declares the param structs inline and imports nothing, so it adds no
 *      dependency on the V3 core/periphery interfaces (which we do not vendor).
 *
 *      Scope: the two single-hop entry points used by the V3 leg of a two-venue arbitrage.
 *      Multi-hop `exactInput` / `exactOutput` are intentionally NOT declared here; add them
 *      only if a strategy actually routes a V3 leg through more than one pool.
 */
interface IUniswapV3Router {
    /// @notice Parameters for a single-hop exact-input swap.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Parameters for a single-hop exact-output swap.
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for `amountOut` of another token.
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}
