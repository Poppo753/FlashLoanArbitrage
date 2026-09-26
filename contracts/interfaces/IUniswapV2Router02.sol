// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV2Router02
 * @notice Canonical Uniswap V2 Router02 ABI (the well-known public interface).
 * @dev This is the complete, standard UniswapV2Router02 interface. It is NOT a
 *      project-specific invention: the selectors below match the canonical
 *      `UniswapV2Router02` contract byte-for-byte, so a deployed router can be
 *      cast to this type without any adapter.
 *
 *      Arbitrum One deployment:
 *        - Router02: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24
 *        - Factory:  0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9
 *
 *      Only the members required for a two-venue (V2 <-> V3) arbitrage are kept.
 *      Pair resolution lives in `IUniswapV2Factory` - the router contract does not
 *      implement `getPair`, so it is deliberately absent here. `factory()` and
 *      `WETH()` are the standard router getters.
 */
interface IUniswapV2Router02 {
    // ============ Core getters ============

    /// @notice Returns the address of the Uniswap V2 factory that deployed pairs behind this router.
    function factory() external view returns (address);

    /// @notice Returns the canonical WETH wrapper address on the current chain.
    function WETH() external view returns (address);

    // ============ Liquidity ============

    /**
     * @notice Adds liquidity for an exact amount of ERC20 tokens.
     * @return amountTokenA The amount of tokenA added
     * @return amountTokenB The amount of tokenB added
     * @return liquidity The amount of liquidity tokens minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountTokenA, uint256 amountTokenB, uint256 liquidity);

    /**
     * @notice Adds liquidity for an exact amount of ERC20 tokens, using native ETH as tokenB.
     * @return amountToken The amount of the ERC20 token added
     * @return amountETH The amount of native ETH added
     * @return liquidity The amount of liquidity tokens minted
     */
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    // ============ Swaps ============

    /**
     * @notice Swaps an exact amount of `path[0]` tokens for as few `path[n-1]` tokens as possible.
     * @param amountIn The amount of the input token
     * @param amountOutMin The minimum acceptable amount of the output token
     * @param path The list of token addresses (the `path.length - 1` elements are pairs used for each swap)
     * @param to The recipient of the output tokens
     * @param deadline Timestamp after which the swap will revert
     * @return amounts The amounts of the input token, and every intermediate token, used for each swap
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Swaps as few `path[0]` tokens as possible for an exact amount of `path[n-1]` tokens.
     * @param amountOut The exact amount of the output token
     * @param amountInMax The maximum acceptable amount of the input token
     * @param path The list of token addresses
     * @param to The recipient of the output tokens
     * @param deadline Timestamp after which the swap will revert
     * @return amounts The amounts of the input token, and every intermediate token, used for each swap
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Swaps an exact amount of native ETH for as few `path[n-1]` tokens as possible.
     * @param path The list of token addresses; `path[0]` must be `WETH()`
     * @return amounts The amounts of every token used for each swap
     */
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    /**
     * @notice Swaps an exact amount of `path[0]` tokens for as few native ETH as possible.
     * @return amounts The amounts of every token used for each swap
     */
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    // ============ Quoting helpers ============

    /**
     * @notice Given an input amount of `path[0]` tokens, returns the maximum output amount of the last token.
     * @dev This function does not check that there is sufficient liquidity in the pool, or that the
     *      intermediate hops are valid. Callers must sanity check the result before trading on it.
     */
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    /**
     * @notice Given an output amount of `path[n-1]` tokens, returns the required input amount of the first token.
     * @dev Does not check for sufficient liquidity or valid intermediate hops.
     */
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);

    /**
     * @notice Given two reserves and an input amount of token A, computes the resulting output amount of token B.
     * @param amountA The input amount of token A
     * @param reserveA The reserves of token A
     * @param reserveB The reserves of token B
     * @return amountB The quoted output amount of token B
     * @dev Canonical shape: `quote` returns a SINGLE value (`amountB`). A second named return
     *      `amountA` cannot be declared because Solidity rejects a return name that repeats a
     *      parameter name ("Identifier already declared"), and returning a second value would
     *      also break the selector match with the deployed router. The effective ABI is
     *      `quote(uint256,uint256,uint256) -> uint256`, exactly as on-chain.
     */
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);
}
