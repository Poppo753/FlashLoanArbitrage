// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router} from "../contracts/interfaces/IUniswapV2Router.sol";
import {IFlashLoanSimpleReceiver} from "../contracts/interfaces/IAaveFlashLoanReceiver.sol";

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
        totalSupply = initialSupply * 10**uint256(_decimals);
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

contract MockAavePool {
    using SafeERC20 for IERC20;

    address public owner;
    uint256 public flashLoanFee = 50;

    mapping(address => uint256) public balances;

    constructor() {
        owner = msg.sender;
    }

    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        bytes calldata params
    ) external {
        require(balances[assets[0]] >= amounts[0], "Insufficient liquidity");
        IERC20(assets[0]).safeTransfer(receiver, amounts[0]);

        uint256 premium = amounts[0] * flashLoanFee / 10000;
        uint256[] memory premiums = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            premiums[i] = amounts[i] * flashLoanFee / 10000;
        }

        (bool success, ) = receiver.call(
            abi.encodeWithSignature(
                "executeOperation(address[],uint256[],uint256[],address,bytes)",
                assets, amounts, premiums, address(this), params
            )
        );
        require(success, "Flash loan execution failed");

        uint256 totalRepayment = amounts[0] + premiums[0];
        require(balances[assets[0]] >= totalRepayment, "Repayment failed");
        IERC20(assets[0]).safeTransferFrom(receiver, address(this), totalRepayment);
    }

    function flashLoanDouble(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        bytes calldata params
    ) external {
        require(balances[assets[0]] >= amounts[0], "Insufficient liquidity");
        IERC20(assets[0]).safeTransfer(receiver, amounts[0]);

        uint256 premium = amounts[0] * flashLoanFee / 10000;
        uint256[] memory premiums = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            premiums[i] = amounts[i] * flashLoanFee / 10000;
        }

        (bool success, ) = receiver.call(
            abi.encodeWithSignature(
                "executeOperation(address[],uint256[],uint256[],address,bytes)",
                assets, amounts, premiums, address(this), params
            )
        );
        require(success, "Flash loan first execution failed");

        (success, ) = receiver.call(
            abi.encodeWithSignature(
                "executeOperation(address[],uint256[],uint256[],address,bytes)",
                assets, amounts, premiums, address(this), params
            )
        );
        require(success, "Flash loan second execution failed");
    }

    function deposit(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[token] += amount;
    }

    function withdraw(address token, uint256 amount) external {
        require(balances[token] >= amount, "Insufficient balance");
        balances[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}

contract MockUniswapRouter is IUniswapV2Router {
    using SafeERC20 for IERC20;

    uint256 public multiplier = 100;
    mapping(address => uint256) public reserves;

    function setMultiplier(uint256 _multiplier) external {
        multiplier = _multiplier;
    }

    function setReserve(address token, uint256 amount) external {
        reserves[token] = amount;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
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

contract MockFlashLoanReceiver is IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    address public executor;
    address public pool;
    bool public executed;
    uint256 public lastProfit;

    constructor(address _executor, address _pool) {
        executor = _executor;
        pool = _pool;
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        executed = true;
        require(msg.sender == pool, "Only pool");

        address borrowAsset = assets[0];
        uint256 borrowAmount = amounts[0];
        uint256 premium = premiums[0];

        (address sellToken, address buyToken, uint256 minAmountOut) = _decodeParams(params);

        uint256 intermediateBalance = IERC20(borrowAsset).balanceOf(address(this));
        IERC20(borrowAsset).forceApprove(executor, intermediateBalance);

        uint256 returned0 = IUniswapV2Router(payable(executor)).swapExactTokensForTokens(
            intermediateBalance,
            0,
            _getPath(borrowAsset, sellToken),
            address(this),
            block.timestamp
        )[1];

        uint256 intermediateTokenBalance = IERC20(sellToken).balanceOf(address(this));
        IERC20(sellToken).forceApprove(executor, intermediateTokenBalance);

        uint256 returned1 = IUniswapV2Router(payable(executor)).swapExactTokensForTokens(
            intermediateTokenBalance,
            minAmountOut,
            _getPath(sellToken, buyToken),
            address(this),
            block.timestamp
        )[1];

        uint256 totalCost = borrowAmount + premium;
        lastProfit = returned1 - totalCost;

        IERC20(borrowAsset).forceApprove(pool, totalCost);
        return true;
    }

    function _decodeParams(bytes calldata params)
        internal pure
        returns (address sellToken, address buyToken, uint256 minAmountOut)
    {
        require(params.length == 64, "Invalid params length");
        (sellToken, buyToken, minAmountOut) = abi.decode(params, (address, address, uint256));
    }

    function _getPath(address from, address to) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = from;
        path[1] = to;
        return path;
    }

    receive() external payable {}
}
