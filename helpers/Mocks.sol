// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router} from "../contracts/interfaces/IUniswapV2Router.sol";

/**
 * @title MockERC20
 * @notice Freely mintable ERC20 with configurable decimals, for local tests.
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 initialSupply) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = initialSupply;
        balanceOf[msg.sender] = totalSupply;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @title MockUniswapRouter
 * @notice Legacy V2-style router mock kept for the minimal `IUniswapV2Router`
 *         surface. The arbitrage plugin uses `IUniswapV2Router02`; see
 *         `ArbMocks.sol` for the router mock that matches it.
 * @dev Pricing is a flat `multiplier` so a test can make one venue cheaper
 *      than another. Retains the reentrancy hook used by the old Aave test
 *      suite, so the same adversarial pattern can be reused against the new
 *      plugin.
 */
contract MockUniswapRouter is IUniswapV2Router {
    using SafeERC20 for IERC20;

    uint256 public multiplier = 100;
    mapping(address => uint256) public reserves;

    address public reenterTarget;
    bytes public reenterData;
    bool public reenterOk;
    bytes public reenterResult;

    function setMultiplier(uint256 _multiplier) external {
        multiplier = _multiplier;
    }

    function setReserve(address token, uint256 amount) external {
        reserves[token] = amount;
    }

    function setReentrancyHook(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        if (reenterTarget != address(0)) {
            (reenterOk, reenterResult) = reenterTarget.call(reenterData);
            reenterTarget = address(0);
        }

        amounts = new uint256[](2);
        amounts[0] = amountIn;

        address tokenIn = path[0];
        address tokenOut = path[1];
        uint256 reserveIn = reserves[tokenIn];
        uint256 reserveOut = reserves[tokenOut];

        require(reserveIn > 0 && reserveOut > 0, "Insufficient reserves");

        uint256 amountOut = amountIn * multiplier / 100;

        require(amountOut >= amountOutMin, "Uniswap: insufficient output amount");
        amounts[1] = amountOut;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        address tokenIn = path[0];
        address tokenOut = path[1];

        require(reserves[tokenIn] > 0 && reserves[tokenOut] > 0, "Insufficient reserves");
        amounts[1] = amountIn * multiplier / 100;
    }
}
