// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/FlashArbExecutor.sol";
import "../contracts/interfaces/IUniswapV2Router.sol";
import "../helpers/Mocks.sol";
import "../helpers/Constants.sol";

contract FlashArbExecutorTest is Test {
    FlashArbExecutor public executor;
    MockAavePool public pool;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockUniswapRouter public router0;
    MockUniswapRouter public router1;
    address public owner;
    address public attackerAddr;

    uint256 constant AMOUNT = 10_000 * 1e18;

    function setUp() public {
        owner = address(this);
        attackerAddr = address(0x133700000000000000000000000000000001);
        vm.deal(attackerAddr, 100 ether);
        vm.deal(address(this), 100 ether);

        pool = new MockAavePool();
        tokenA = new MockERC20("TokenA", "TKA", 18, 1_000_000 * 1e18);
        tokenB = new MockERC20("TokenB", "TKB", 18, 1_000_000 * 1e18);
        tokenC = new MockERC20("TokenC", "TKC", 18, 1_000_000 * 1e18);
        router0 = new MockUniswapRouter();
        router1 = new MockUniswapRouter();

        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        tokenC.approve(address(pool), type(uint256).max);

        router0.setReserve(address(tokenA), 1_000_000 * 1e18);
        router0.setReserve(address(tokenB), 1_000_000 * 1e18);
        router1.setReserve(address(tokenA), 1_000_000 * 1e18);
        router1.setReserve(address(tokenB), 1_000_000 * 1e18);
        router1.setReserve(address(tokenC), 1_000_000 * 1e18);

        tokenB.mint(address(router0), 1_000_000 * 1e18);
        tokenA.mint(address(router1), 1_000_000 * 1e18);
        tokenC.mint(address(router1), 1_000_000 * 1e18);

        router0.setMultiplier(150);
        router1.setMultiplier(150);

        executor =
            new FlashArbExecutor(address(pool), owner, Constants.MIN_PROFIT_BPS, address(router0), address(router1));
    }

    receive() external payable {}

    function _buildParams(address sellToken, address buyToken, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(sellToken, buyToken, minAmountOut);
    }

    function _setupProfitableFlashLoan() internal {
        pool.deposit(address(tokenA), AMOUNT);
        tokenA.mint(address(executor), AMOUNT);
        tokenA.approve(address(router0), AMOUNT);
    }

    function test_ExecuteOperation_Success() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        address[] memory assets = new address[](1);
        assets[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = AMOUNT * 50 / 10000;

        bytes memory params = _buildParams(address(tokenB), address(tokenA), 0);

        vm.prank(address(pool));
        bool result = executor.executeOperation(assets, amounts, premiums, address(this), params);
        assertTrue(result);
    }

    function test_ExecuteOperation_NoProfit_Reverts() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        router0.setMultiplier(50);
        router1.setMultiplier(50);

        address[] memory assets = new address[](1);
        assets[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = AMOUNT * 50 / 10000;

        bytes memory params = _buildParams(address(tokenB), address(tokenA), 0);

        vm.prank(address(pool));
        vm.expectRevert(InsufficientProfit.selector);
        executor.executeOperation(assets, amounts, premiums, address(this), params);
    }

    function test_ExecuteOperation_WrongBuyAsset_Reverts() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        address[] memory assets = new address[](1);
        assets[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = AMOUNT * 50 / 10000;

        bytes memory params = _buildParams(address(tokenB), address(tokenC), 0);

        vm.prank(address(pool));
        vm.expectRevert(InvalidBuyAsset.selector);
        executor.executeOperation(assets, amounts, premiums, address(this), params);
    }

    function test_OnlyPool_Caller() public {
        vm.expectRevert(OnlyPoolCaller.selector);
        executor.executeOperation(new address[](1), new uint256[](1), new uint256[](1), address(this), bytes(""));
    }

    function test_OnlyOwner_Caller() public {
        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.executeArbitrage(address(tokenA), AMOUNT, _buildParams(address(tokenB), address(tokenA), 0));
    }

    function test_ReentrancyProtection() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        address[] memory assets = new address[](1);
        assets[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = AMOUNT * 50 / 10000;

        bytes memory params = _buildParams(address(tokenB), address(tokenA), 0);

        bytes memory reenterCall = abi.encodeWithSelector(
            FlashArbExecutor.executeOperation.selector, assets, amounts, premiums, address(this), params
        );
        router0.setReentrancyHook(address(executor), reenterCall);

        vm.prank(owner);
        executor.executeArbitrage(address(tokenA), AMOUNT, params);

        assertFalse(router0.reenterOk());
        assertEq(
            keccak256(router0.reenterResult()),
            keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"))
        );
    }

    function test_WithdrawToken_OwnerOnly() public {
        tokenA.mint(address(executor), 1000 * 1e18);

        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.withdrawToken(address(tokenA));

        uint256 balanceBefore = tokenA.balanceOf(owner);
        vm.prank(owner);
        executor.withdrawToken(address(tokenA));
        assertEq(tokenA.balanceOf(owner), balanceBefore + 1000 * 1e18);
        assertEq(tokenA.balanceOf(address(executor)), 0);
    }

    function test_WithdrawETH_OwnerOnly() public {
        payable(address(executor)).transfer(1 ether);
        assertEq(address(executor).balance, 1 ether);

        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.withdrawETH();

        uint256 balanceBefore = address(owner).balance;
        vm.prank(owner);
        executor.withdrawETH();
        assertEq(address(owner).balance, balanceBefore + 1 ether);
        assertEq(address(executor).balance, 0);
    }

    function test_WithdrawETH_SupportsContractOwner() public {
        GasHogOwner hog = new GasHogOwner();
        FlashArbExecutor hogExecutor = new FlashArbExecutor(
            address(pool), address(hog), Constants.MIN_PROFIT_BPS, address(router0), address(router1)
        );
        payable(address(hogExecutor)).transfer(1 ether);

        hog.withdraw(hogExecutor);

        assertEq(address(hogExecutor).balance, 0);
        assertEq(address(hog).balance, 1 ether);
        assertEq(hog.withdrawals(), 1);
    }

    function test_FlashLoanRepayment_Exact() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        router0.setMultiplier(150);
        router1.setMultiplier(150);

        uint256 beforePoolTokenBalance = tokenA.balanceOf(address(pool));

        vm.prank(owner);
        executor.executeArbitrage(address(tokenA), AMOUNT, _buildParams(address(tokenB), address(tokenA), 0));

        uint256 afterPoolTokenBalance = tokenA.balanceOf(address(pool));
        assertGt(afterPoolTokenBalance, beforePoolTokenBalance);
        uint256 premium = AMOUNT * 50 / 10000;
        assertEq(afterPoolTokenBalance, beforePoolTokenBalance + premium);
    }

    function test_Paused_CircuitBreaker() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        router0.setMultiplier(150);
        router1.setMultiplier(150);

        address[] memory assets = new address[](1);
        assets[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = AMOUNT * 50 / 10000;

        bytes memory params = _buildParams(address(tokenB), address(tokenA), 0);

        vm.prank(owner);
        executor.pause();

        vm.prank(address(pool));
        vm.expectRevert("Paused");
        executor.executeOperation(assets, amounts, premiums, address(this), params);

        vm.prank(owner);
        executor.unpause();

        vm.prank(address(pool));
        bool result = executor.executeOperation(assets, amounts, premiums, address(this), params);
        assertTrue(result);
    }

    function test_ExecuteArbitrage_OnlyOwner() public {
        _setupProfitableFlashLoan();
        pool.deposit(address(tokenA), AMOUNT);

        vm.prank(owner);
        executor.executeArbitrage(address(tokenA), AMOUNT, _buildParams(address(tokenB), address(tokenA), 0));

        assertGt(tokenA.balanceOf(address(executor)), 0);
    }

    function test_Pause_Unpause_OwnerOnly() public {
        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.pause();

        vm.prank(owner);
        executor.pause();
        assertTrue(executor.paused());

        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.unpause();

        vm.prank(owner);
        executor.unpause();
        assertFalse(executor.paused());
    }
}

contract GasHogOwner {
    uint256 public withdrawals;

    function withdraw(FlashArbExecutor executor) external {
        executor.withdrawETH();
    }

    receive() external payable {
        withdrawals += 1;
    }
}
