// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UniswapV2Strategy} from "../src/strategies/UniswapV2Strategy.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal Uniswap V2 mocks — just enough to test strategy logic
// ─────────────────────────────────────────────────────────────────────────────

contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32  public blockTimestampLast;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    // Test helper: set reserves directly
    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = uint32(block.timestamp);
        // Update cumulative prices
        if (r0 > 0 && r1 > 0) {
            price0CumulativeLast += uint256(uint224((uint256(r1) << 112) / r0));
            price1CumulativeLast += uint256(uint224((uint256(r0) << 112) / r1));
        }
    }

    // Mock addLiquidity result: mint LP tokens to strategy
    function mockMint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address, uint256) external returns (bool) { return true; }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockUniswapV2Router {
    bool public usedFeeOnTransferVariant;
    bool public shouldRevert;

    // Simulate addLiquidity: returns fixed amounts
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256, uint256,
        address, uint256
    ) external returns (uint256, uint256, uint256 liquidity) {
        if (shouldRevert) revert("MockRouter: revert");
        // Use 99% of desired amounts (simulates minor slippage)
        return (amountADesired * 99 / 100, amountBDesired * 99 / 100, amountADesired * 99 / 100);
    }

    // Standard swap
    function swapExactTokensForTokens(
        uint256 amountIn, uint256,
        address[] calldata path,
        address to, uint256
    ) external returns (uint256[] memory amounts) {
        // Transfer output token to recipient (simulate swap)
        MockERC20(path[path.length - 1]).mint(to, amountIn * 99 / 100);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 99 / 100;
    }

    // Fee-on-transfer swap — records that this variant was called
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256,
        address[] calldata path,
        address to, uint256
    ) external {
        usedFeeOnTransferVariant = true;
        // Simulate: fee-on-transfer token already deducted fee, output is less
        MockERC20(path[path.length - 1]).mint(to, amountIn * 98 / 100);
    }

    function removeLiquidity(
        address tokenA, address,
        uint256 liquidity, uint256, uint256,
        address to, uint256
    ) external returns (uint256 amountA, uint256 amountB) {
        MockERC20(tokenA).mint(to, liquidity);
        return (liquidity, liquidity / 100);
    }

    function setRevert(bool _revert) external { shouldRevert = _revert; }
    function resetFeeOnTransferFlag() external { usedFeeOnTransferVariant = false; }
}

// ─────────────────────────────────────────────────────────────────────────────
// UniswapV2Strategy Tests
// ─────────────────────────────────────────────────────────────────────────────

contract UniswapV2StrategyTest is Test {

    // Contracts
    MockERC20             kgst;
    MockERC20             deen;        // normal token
    MockFeeOnTransferERC20 paxg;       // fee-on-transfer token
    MockUniswapV2Pair     deenPair;
    MockUniswapV2Pair     paxgPair;
    MockUniswapV2Router   router;
    FeeDistributor        feeDistributor;

    UniswapV2Strategy     deenStrategy;  // feeOnTransfer = false
    UniswapV2Strategy     paxgStrategy;  // feeOnTransfer = true

    // Actors
    address founder  = makeAddr("founder");
    address vault    = makeAddr("vault");
    address manager  = makeAddr("manager");
    address keeper   = makeAddr("keeper");
    address deployer = makeAddr("deployer");

    uint256 constant INITIAL_RESERVES = 100_000 ether;

    function setUp() public {
        vm.startPrank(deployer);

        // Tokens
        kgst = new MockERC20("KGST", "KGST", 18);
        deen = new MockERC20("DEEN", "DEEN", 18);
        paxg = new MockFeeOnTransferERC20("PAXG", "PAXG");

        // Pairs
        deenPair = new MockUniswapV2Pair(address(kgst), address(deen));
        paxgPair = new MockUniswapV2Pair(address(kgst), address(paxg));

        // Seed pair reserves so TWAP can initialize
        deenPair.setReserves(uint112(INITIAL_RESERVES), uint112(INITIAL_RESERVES / 85)); // 1 DEEN ≈ 85 KGST
        paxgPair.setReserves(uint112(INITIAL_RESERVES), uint112(INITIAL_RESERVES / 7700)); // 1 PAXG ≈ 7700 KGST

        router = new MockUniswapV2Router();

        // FeeDistributor
        feeDistributor = new FeeDistributor(address(kgst), founder);
        FeeDistributor.Recipient[] memory r = new FeeDistributor.Recipient[](1);
        r[0] = FeeDistributor.Recipient({ account: makeAddr("team"), shareBps: 8000 });
        feeDistributor.setRecipients(r);

        // DEEN strategy — normal ERC20
        deenStrategy = new UniswapV2Strategy(
            address(kgst),
            address(deen),
            address(deenPair),
            address(router),
            address(feeDistributor),
            false // feeOnTransfer = false
        );

        // PAXG strategy — fee-on-transfer ERC20
        paxgStrategy = new UniswapV2Strategy(
            address(kgst),
            address(paxg),
            address(paxgPair),
            address(router),
            address(feeDistributor),
            true  // feeOnTransfer = true
        );

        // Grant roles
        deenStrategy.grantRole(deenStrategy.VAULT_ROLE(),    vault);
        deenStrategy.grantRole(deenStrategy.MANAGER_ROLE(),  manager);
        deenStrategy.grantRole(deenStrategy.KEEPER_ROLE(),   keeper);

        paxgStrategy.grantRole(paxgStrategy.VAULT_ROLE(),    vault);
        paxgStrategy.grantRole(paxgStrategy.MANAGER_ROLE(),  manager);
        paxgStrategy.grantRole(paxgStrategy.KEEPER_ROLE(),   keeper);

        feeDistributor.grantRole(feeDistributor.STRATEGY_ROLE(), address(deenStrategy));
        feeDistributor.grantRole(feeDistributor.STRATEGY_ROLE(), address(paxgStrategy));

        vm.stopPrank();
    }

    // ── Constructor tests ─────────────────────────────────────────────────────

    function test_constructor_deenStrategy_flagIsFalse() public view {
        assertFalse(deenStrategy.otherTokenFeeOnTransfer());
    }

    function test_constructor_paxgStrategy_flagIsTrue() public view {
        assertTrue(paxgStrategy.otherTokenFeeOnTransfer());
    }

    function test_constructor_setsTokensCorrectly() public view {
        assertEq(address(deenStrategy.asset()),      address(kgst));
        assertEq(address(deenStrategy.otherToken()), address(deen));
        assertEq(address(paxgStrategy.otherToken()), address(paxg));
    }

    function test_constructor_revertOnIdenticalTokens() public {
        vm.expectRevert("V2Strategy: identical tokens");
        new UniswapV2Strategy(
            address(kgst), address(kgst),
            address(deenPair), address(router),
            address(feeDistributor), false
        );
    }

    function test_constructor_revertOnZeroAddresses() public {
        vm.expectRevert("V2Strategy: zero asset");
        new UniswapV2Strategy(
            address(0), address(deen),
            address(deenPair), address(router),
            address(feeDistributor), false
        );
    }

    // ── Fee-on-transfer flag — core feature ───────────────────────────────────

    function test_paxgStrategy_usesFeOnTransferSwap() public {
        _initializeTwap(paxgStrategy, paxgPair);

        kgst.mint(vault, 1000 ether);
        vm.startPrank(vault);
        kgst.approve(address(paxgStrategy), 1000 ether);

        router.resetFeeOnTransferFlag();
        paxgStrategy.deposit(1000 ether);
        vm.stopPrank();

        assertTrue(
            router.usedFeeOnTransferVariant(),
            "PAXG strategy must use swapExactTokensForTokensSupportingFeeOnTransferTokens"
        );
    }

    function test_deenStrategy_doesNotUseFeeOnTransferSwap() public {
        _initializeTwap(deenStrategy, deenPair);

        kgst.mint(vault, 1000 ether);
        vm.startPrank(vault);
        kgst.approve(address(deenStrategy), 1000 ether);

        router.resetFeeOnTransferFlag();
        deenStrategy.deposit(1000 ether);
        vm.stopPrank();

        assertFalse(
            router.usedFeeOnTransferVariant(),
            "DEEN strategy must NOT use fee-on-transfer swap variant"
        );
    }

    // ── deposit() ─────────────────────────────────────────────────────────────

    function test_deposit_requiresVaultRole() public {
        kgst.mint(address(this), 100 ether);
        kgst.approve(address(deenStrategy), 100 ether);
        vm.expectRevert();
        deenStrategy.deposit(100 ether);
    }

    function test_deposit_requiresTwapInitialized() public {
        // Fresh strategy without TWAP initialized
        vm.startPrank(deployer);
        UniswapV2Strategy fresh = new UniswapV2Strategy(
            address(kgst), address(deen),
            address(deenPair), address(router),
            address(feeDistributor), false
        );
        fresh.grantRole(fresh.VAULT_ROLE(), vault);
        vm.stopPrank();

        kgst.mint(vault, 100 ether);
        vm.startPrank(vault);
        kgst.approve(address(fresh), 100 ether);
        vm.expectRevert("V2Strategy: TWAP not initialized");
        fresh.deposit(100 ether);
        vm.stopPrank();
    }

    function test_deposit_updatesTotalLpHeld() public {
        _initializeTwap(deenStrategy, deenPair);

        uint256 amount = 1000 ether;
        kgst.mint(vault, amount);
        vm.startPrank(vault);
        kgst.approve(address(deenStrategy), amount);
        deenStrategy.deposit(amount);
        vm.stopPrank();

        assertGt(deenStrategy.totalLpHeld(), 0);
    }

    function test_deposit_updatesTotalDepositedKgst() public {
        _initializeTwap(deenStrategy, deenPair);

        uint256 amount = 1000 ether;
        kgst.mint(vault, amount);
        vm.startPrank(vault);
        kgst.approve(address(deenStrategy), amount);
        deenStrategy.deposit(amount);
        vm.stopPrank();

        assertEq(deenStrategy.totalDepositedKgst(), amount);
    }

    function test_deposit_revertOnZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert("V2Strategy: zero amount");
        deenStrategy.deposit(0);
    }

    // ── withdraw() ────────────────────────────────────────────────────────────

    function test_withdraw_requiresVaultRole() public {
        vm.expectRevert();
        deenStrategy.withdraw(100 ether);
    }

    function test_withdraw_revertInsufficientLP() public {
        vm.prank(vault);
        vm.expectRevert("V2Strategy: insufficient LP");
        deenStrategy.withdraw(1 ether);
    }

    function test_withdraw_reducesTotalLpHeld() public {
        _initializeTwap(deenStrategy, deenPair);
        uint256 lp = _depositToStrategy(deenStrategy, 1000 ether);

        vm.prank(vault);
        deenStrategy.withdraw(lp / 2);

        assertEq(deenStrategy.totalLpHeld(), lp - lp / 2);
    }

    // ── emergencyWithdraw() ───────────────────────────────────────────────────

    function test_emergencyWithdraw_requiresManagerRole() public {
        vm.expectRevert();
        deenStrategy.emergencyWithdraw(100 ether);
    }

    function test_emergencyWithdraw_clearsLpHeld() public {
        _initializeTwap(deenStrategy, deenPair);
        _depositToStrategy(deenStrategy, 1000 ether);

        vm.prank(manager);
        deenStrategy.emergencyWithdraw(type(uint256).max);

        assertEq(deenStrategy.totalLpHeld(), 0);
        assertEq(deenStrategy.totalDepositedKgst(), 0);
    }

    // ── setSlippage() ─────────────────────────────────────────────────────────

    function test_setSlippage_onlyManager() public {
        vm.expectRevert();
        deenStrategy.setSlippage(100);
    }

    function test_setSlippage_updatesValue() public {
        vm.prank(manager);
        deenStrategy.setSlippage(100);
        assertEq(deenStrategy.slippageBps(), 100);
    }

    function test_setSlippage_revertAbove5Percent() public {
        vm.prank(manager);
        vm.expectRevert("V2Strategy: slippage > 5%");
        deenStrategy.setSlippage(501);
    }

    // ── harvest() ─────────────────────────────────────────────────────────────

    function test_harvest_requiresKeeperRole() public {
        vm.expectRevert();
        deenStrategy.harvest();
    }

    function test_harvest_respectsCooldown() public {
        _initializeTwap(deenStrategy, deenPair);
        _depositToStrategy(deenStrategy, 1000 ether);

        // First harvest
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        deenStrategy.harvest();

        // Second harvest immediately — should fail
        vm.prank(keeper);
        vm.expectRevert("V2Strategy: cooldown");
        deenStrategy.harvest();
    }

    function test_forceHarvest_onlyManager() public {
        vm.expectRevert();
        deenStrategy.forceHarvest();
    }

    // ── totalValue() ──────────────────────────────────────────────────────────

    function test_totalValue_zeroBeforeDeposit() public view {
        assertEq(deenStrategy.totalValue(), 0);
    }

    function test_totalValue_nonZeroAfterDeposit() public {
        _initializeTwap(deenStrategy, deenPair);
        _depositToStrategy(deenStrategy, 1000 ether);
        assertGt(deenStrategy.totalValue(), 0);
    }

    // ── checkImpermanentLoss() ────────────────────────────────────────────────

    function test_checkIL_trueBeforeDeposit() public view {
        assertTrue(deenStrategy.checkImpermanentLoss());
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_deposit_tracksDepositedAmount(uint256 amount) public {
        vm.assume(amount > 1e18 && amount < 10_000_000 ether);
        _initializeTwap(deenStrategy, deenPair);

        kgst.mint(vault, amount);
        vm.startPrank(vault);
        kgst.approve(address(deenStrategy), amount);
        deenStrategy.deposit(amount);
        vm.stopPrank();

        assertEq(deenStrategy.totalDepositedKgst(), amount);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Warp time forward to initialize TWAP (requires 30 min elapsed)
    function _initializeTwap(UniswapV2Strategy strat, MockUniswapV2Pair pair_) internal {
        // Grant manager role to this test contract
        vm.startPrank(deployer);
        strat.grantRole(strat.MANAGER_ROLE(), address(this));
        vm.stopPrank();

        // First call: sets blockTimestampLast and priceCumulativeLast
        pair_.setReserves(pair_.reserve0(), pair_.reserve1());
        strat.initializeTwap();

        // Advance time past TWAP_PERIOD so timeElapsed >= TWAP_PERIOD
        vm.warp(block.timestamp + 31 minutes);
        pair_.setReserves(pair_.reserve0(), pair_.reserve1());

        // Second call: now timeElapsed >= TWAP_PERIOD → twapInitialized = true
        strat.initializeTwap();
    }

    function _depositToStrategy(UniswapV2Strategy strat, uint256 amount)
        internal returns (uint256 lp)
    {
        // Ensure TWAP is initialized
        vm.warp(block.timestamp + 31 minutes);

        kgst.mint(vault, amount);
        vm.startPrank(vault);
        kgst.approve(address(strat), amount);
        lp = strat.deposit(amount);
        vm.stopPrank();
    }
}
