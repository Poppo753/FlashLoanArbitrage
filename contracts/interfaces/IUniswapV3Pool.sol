// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV3Pool
 * @notice Read-only slice of a Uniswap V3 pool: just enough for slot0-based price quoting.
 * @dev READ ONLY. This interface exists purely to read state (current price + liquidity) when
 *      estimating a V3 price on-chain or in a fork test. Swaps and liquidity changes must go
 *      through `IUniswapV3Router` - never call into the pool directly, because the pool only
 *      accepts calls from its own periphery contracts.
 *
 *      Note: `sqrtPriceX96` is the spot price of token1 in terms of token0, NOT an executable
 *      quote. For an executable quote use `IUniswapV3QuoterV2` (0x61fFE014bA17989E743c5F6cB21bF9697530B21e).
 */
interface IUniswapV3Pool {
    /**
     * @notice The 0th storage slot of the pool, exposed as a single method to save gas.
     * @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
     * @return tick The current tick, according to the last tick transition that was run
     * @return observationIndex The index of the last oracle observation that was written
     * @return observationCardinality The current maximum number of observations stored
     * @return observationCardinalityNext The next maximum number of observations
     * @return feeProtocol The protocol fee for both tokens of the pool
     * @return unlocked Whether the pool is currently locked against reentrancy
     */
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice The amount of liquidity currently active in the pool, in Q64.96 units.
    function liquidity() external view returns (uint128);
}
