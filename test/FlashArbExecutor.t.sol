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

        pool = new MockAavePool();
        tokenA = new MockERC20("TokenA", "TKA", 18, 1_000_000 * 1e18);
        tokenB = new MockERC20("TokenB", "TKB", 18, 1_000_000 * 1e18);
        tokenC = new MockERC20("TokenC", "TKC", 18, 1_000_000 * 1e18);
        router0 = new MockUniswapRouter();
        router1 = new MockUniswapRouter();

        router0.setReserve(address(tokenA), 1_000_000 * 1e18);
        router0.setReserve(address(tokenB), 1_000_000 * 1e18);
        router1.setReserve(address(tokenB), 1_000_000 * 1e18);
        router1.setReserve(address(tokenC), 1_000_000 * 1e18);

        router0.setMultiplier(150);
        router1.setMultiplier(150);

        executor = new FlashArbExecutor(
            address(pool),
            owner,
            Constants.MIN_PROFIT_BPS,
            address(router0),
            address(router1)
        );
    }

    function _buildParams(address sellToken, address buyToken, uint256 minAmountOut) internal pure returns (bytes memory) {
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

        bytes memory params = _buildParams(address(tokenB), address(tokenC), 0);

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

        bytes memory params = _buildParams(address(tokenB), address(tokenC), 0);

        vm.prank(address(pool));
        vm.expectRevert(InsufficientProfit.selector);
        executor.executeOperation(assets, amounts, premiums, address(this), params);
    }

    function test_OnlyPool_Caller() public {
        vm.expectRevert(OnlyPoolCaller.selector);
        executor.executeOperation(
            new address[](1),
            new uint256[](1),
            new uint256[](1),
            address(this),
            bytes("")
        );
    }

    function test_OnlyOwner_Caller() public {
        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.executeArbitrage(
            address(tokenA),
            AMOUNT,
            _buildParams(address(tokenB), address(tokenC), 0)
        );
    }

    function test_ReentrancyProtection() public {
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

        bytes memory params = _buildParams(address(tokenB), address(tokenC), 0);

        ReentrancyAttacker attacker = new ReentrancyAttacker(
            address(executor),
            address(pool),
            assets,
            amounts,
            premiums,
            params
        );

        vm.expectRevert();
        attacker.attack();
    }

    function test_WithdrawToken_OwnerOnly() public {
        tokenA.mint(address(executor), 1000 * 1e18);

        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.withdrawToken(address(tokenA));

        vm.prank(owner);
        executor.withdrawToken(address(tokenA));
        assertEq(tokenA.balanceOf(owner), 1000 * 1e18);
    }

    function test_WithdrawETH_OwnerOnly() public {
        payable(address(executor)).transfer(1 ether);
        assertEq(address(executor).balance, 1 ether);

        vm.prank(attackerAddr);
        vm.expectRevert();
        executor.withdrawETH();

        vm.prank(owner);
        executor.withdrawETH();
        assertEq(address(owner).balance, 1 ether);
    }

    function test_FlashLoanRepayment_Exact() public {
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

        bytes memory params = _buildParams(address(tokenB), address(tokenC), 0);

        uint256 beforePoolTokenBalance = tokenA.balanceOf(address(pool));

        vm.prank(address(pool));
        executor.executeOperation(assets, amounts, premiums, address(this), params);

        uint256 afterPoolTokenBalance = tokenA.balanceOf(address(pool));
        assertGt(afterPoolTokenBalance, beforePoolTokenBalance);
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

        bytes memory params = _buildParams(address(tokenB), address(tokenC), 0);

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
        vm.prank(owner);
        executor.executeArbitrage(address(tokenA), AMOUNT, _buildParams(address(tokenB), address(tokenC), 0));
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

contract ReentrancyAttacker {
    FlashArbExecutor public executor;
    MockAavePool public pool;
    address[] assets;
    uint256[] amounts;
    uint256[] premiums;
    bytes params;
    bool public reentered;

    constructor(
        address _executor,
        address _pool,
        address[] memory _assets,
        uint256[] memory _amounts,
        uint256[] memory _premiums,
        bytes memory _params
    ) {
        executor = FlashArbExecutor(payable(_executor));
        pool = MockAavePool(_pool);
        assets = _assets;
        amounts = _amounts;
        premiums = _premiums;
        params = _params;
    }

    function attack() external {
        pool.flashLoanDouble(address(executor), assets, amounts, params);
    }

    receive() external payable {}
}
