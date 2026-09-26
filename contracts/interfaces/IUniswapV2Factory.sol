// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV2Factory
 * @notice Minimal Uniswap V2 factory interface: pair address resolution.
 * @dev The factory - not the router - is the contract that implements `getPair`.
 *      Reading it from the router contract would revert.
 *
 *      Arbitrum One deployment:
 *        - Factory: 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9
 *        - Router02: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24 (see IUniswapV2Router02)
 *
 *      `getPair` is deterministic and permissionless: the pair address is a
 *      CREATE2 computation over (tokenA, tokenB, initCodeHash), so the same two
 *      token addresses always resolve to the same pair on a given factory.
 */
interface IUniswapV2Factory {
    /// @notice Returns the pair contract for two tokens, or address(0) if it does not exist.
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /// @notice Number of pairs deployed by this factory.
    function allPairsLength() external view returns (uint256);

    /// @notice The fee recipient set in the factory.
    function feeTo() external view returns (address);
}
