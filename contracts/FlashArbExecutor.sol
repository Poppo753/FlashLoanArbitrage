// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {IFlashLoanSimpleReceiver} from "./interfaces/IAaveFlashLoanReceiver.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMathLib} from "./libraries/SafeMathLib.sol";

contract FlashArbExecutor is IFlashLoanSimpleReceiver, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using SafeMathLib for uint256;

    event ArbitrageStarted(address indexed borrowAsset, uint256 amount, bytes32 paramsHash);
    event ArbitrageCompleted(address indexed borrowAsset, uint256 profitBps, uint256 netProfit);

    IPool public immutable POOL;
    uint256 public minProfitBps;
    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    IUniswapV2Router public immutable router0;
    IUniswapV2Router public immutable router1;

    constructor(
        address poolAddress,
        address admin,
        uint256 _minProfitBps,
        address router0Address,
        address router1Address
    ) Ownable(admin) {
        POOL = IPool(poolAddress);
        minProfitBps = _minProfitBps;
        router0 = IUniswapV2Router(router0Address);
        router1 = IUniswapV2Router(router1Address);
    }

    function executeArbitrage(address borrowAsset, uint256 amount, bytes calldata params) external onlyOwner {
        emit ArbitrageStarted(borrowAsset, amount, keccak256(params));

        address[] memory assets = new address[](1);
        assets[0] = borrowAsset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        POOL.flashLoan(address(this), assets, amounts, new uint256[](1), address(this), params, 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external nonReentrant whenNotPaused returns (bool) {
        if (msg.sender != address(POOL)) {
            revert OnlyPoolCaller();
        }

        (address sellToken, address buyToken, uint256 minAmountOut) = _decodeParams(params);

        address borrowAsset = assets[0];

        if (buyToken != borrowAsset) {
            revert InvalidBuyAsset();
        }

        uint256 borrowAmount = amounts[0];
        uint256 premium = premiums[0];

        uint256 intermediateBalance = IERC20(borrowAsset).balanceOf(address(this));

        IERC20(borrowAsset).forceApprove(address(router0), intermediateBalance);
        uint256 returned0 = router0.swapExactTokensForTokens(
            intermediateBalance, 0, _getPath(borrowAsset, sellToken), address(this), block.timestamp
        )[1];

        uint256 intermediateTokenBalance = IERC20(sellToken).balanceOf(address(this));

        IERC20(sellToken).forceApprove(address(router1), intermediateTokenBalance);
        uint256 returned1 = router1.swapExactTokensForTokens(
            intermediateTokenBalance, minAmountOut, _getPath(sellToken, buyToken), address(this), block.timestamp
        )[1];

        uint256 totalCost = borrowAmount.add(premium);
        uint256 minRequiredProfit = totalCost.mul(minProfitBps).div(10000);

        if (returned1 <= totalCost || returned1 - totalCost < minRequiredProfit) {
            revert InsufficientProfit();
        }

        uint256 profit = returned1 - totalCost;

        IERC20(borrowAsset).forceApprove(address(POOL), totalCost);

        emit ArbitrageCompleted(borrowAsset, profit.mul(10000).div(totalCost), profit);

        return true;
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function withdrawToken(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function withdrawETH() external onlyOwner {
        (bool success,) = payable(owner()).call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    function _decodeParams(bytes calldata params)
        internal
        pure
        returns (address sellToken, address buyToken, uint256 minAmountOut)
    {
        require(params.length == 96, "Invalid params length");
        (sellToken, buyToken, minAmountOut) = abi.decode(params, (address, address, uint256));
    }

    function _getPath(address from, address to) internal view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = from;
        path[1] = to;
        return path;
    }

    receive() external payable {}
}

error OnlyPoolCaller();
error InsufficientProfit();
error InvalidBuyAsset();
