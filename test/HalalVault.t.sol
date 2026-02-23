// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {HalalVault} from "../src/HalalVault.sol";
import {ShariahGuard} from "../src/ShariahGuard.sol";
import {StrategyRouter} from "../src/StrategyRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockShariahOracle} from "./mocks/MockShariahOracle.sol";

contract HalalVaultTest is Test {
    HalalVault public vault;
    MockERC20 public kgst;
    ShariahGuard public guard;
    StrategyRouter public router;
    address public user = address(0x1234);
    address public admin = address(this);

    function setUp() public {
        kgst = new MockERC20("KGST", "KGST", 18);
        guard = new ShariahGuard(address(0));
        vault = new HalalVault(IERC20(address(kgst)), address(guard), "Halal Vault", "hvKGST");
        router = new StrategyRouter(address(kgst), address(vault));
        vault.setStrategyRouter(address(router));
        vault.grantRole(vault.MANAGER_ROLE(), admin);
        kgst.mint(user, 1_000_000e18);
    }

    function testConstructor() public view {
        assertEq(vault.name(), "Halal Vault");
        assertEq(vault.symbol(), "hvKGST");
        assertEq(address(vault.asset()), address(kgst));
        assertEq(address(vault.shariahGuard()), address(guard));
    }

    function testDeposit() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, user);
        assertEq(shares, 100e18 * 1000);
        assertEq(vault.balanceOf(user), 100e18 * 1000);
        assertEq(vault.totalAssets(), 100e18);
        vm.stopPrank();
    }

    function testDepositWithRegion() public {
        MockShariahOracle regional = new MockShariahOracle(true);
        guard.setRegionalOracle(keccak256("KG"), address(regional));

        vm.startPrank(user);
        kgst.approve(address(vault), 200e18);
        uint256 shares = vault.depositWithRegion(200e18, user, keccak256("KG"));
        assertEq(shares, 200e18 * 1000);
        vm.stopPrank();
    }

    function testShariahRejection() public {
        MockShariahOracle rejecting = new MockShariahOracle(false);
        guard.setGlobalOracle(address(rejecting));

        vm.startPrank(user);
        kgst.approve(address(vault), 50e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahGuard.ShariahViolation.selector,
                "global-override"
            )
        );
        vault.deposit(50e18, user);
        vm.stopPrank();
    }

    function testWithdraw() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 500e18);
        vault.deposit(500e18, user);
        
        vm.warp(block.timestamp + 1 hours);
        
        vault.withdraw(50e18, user, user);
        assertEq(kgst.balanceOf(user), 999_550e18);
        assertEq(vault.totalAssets(), 450e18);
        vm.stopPrank();
    }

    function testDepositLockTime() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 500e18);
        vault.deposit(500e18, user);
        
        vm.expectRevert();
        vault.withdraw(100e18, user, user);
        
        vm.warp(block.timestamp + 1 hours);
        vault.withdraw(50e18, user, user);
        vm.stopPrank();
    }

    function testMaxWithdrawLimit() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 10_000e18);
        vault.deposit(10_000e18, user);

        vm.warp(block.timestamp + 1 hours);

        uint256 max = vault.maxWithdraw(user);
        assertEq(max, 1_000e18, "Day 0: max should be 10% of 10000");

        vault.withdraw(max, user, user);
        assertEq(vault.maxWithdraw(user), 0, "Day 0: after max withdrawal, limit exhausted");

        vm.warp(block.timestamp + 1 days);
        uint256 newMax = vault.maxWithdraw(user);
        assertEq(newMax, 900e18, "Day 1: max should be 10% of remaining 9000");

        vm.stopPrank();
    }

    function testBridgeDeposit() public {
        vault.grantRole(vault.BRIDGE_ROLE(), admin);
        kgst.mint(address(this), 300e18);
        kgst.approve(address(vault), 300e18);
        vault.bridgeDeposit(300e18, user);
        assertGt(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), 300e18);
    }

    function testBridgeDepositShariahRejection() public {
        MockShariahOracle rejecting = new MockShariahOracle(false);
        guard.setGlobalOracle(address(rejecting));

        vault.grantRole(vault.BRIDGE_ROLE(), admin);
        kgst.mint(address(this), 300e18);
        kgst.approve(address(vault), 300e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahGuard.ShariahViolation.selector,
                "global-override"
            )
        );
        vault.bridgeDeposit(300e18, user);
    }

    function testMinimumFirstDeposit() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                HalalVault.FirstDepositTooSmall.selector,
                vault.MIN_FIRST_DEPOSIT()
            )
        );
        vault.deposit(1000, user);
        vm.stopPrank();
    }

    function testVirtualSharesProtection() public {
        address attacker = address(0x666);
        kgst.mint(attacker, 20_000e18);

        vm.startPrank(attacker);
        kgst.approve(address(vault), 20_000e18);
        vault.deposit(vault.MIN_FIRST_DEPOSIT(), attacker);
        
        kgst.transfer(address(vault), 10_000e18);
        vm.stopPrank();

        vm.startPrank(user);
        kgst.approve(address(vault), 10_000e18);
        uint256 shares = vault.deposit(10_000e18, user);
        
        assertTrue(shares > 1, "Virtual shares prevent inflation attack");
        vm.stopPrank();
    }

    function testPause() public {
        vault.grantRole(vault.GUARDIAN_ROLE(), admin);
        vm.startPrank(user);
        kgst.approve(address(vault), 100e18);
        vault.deposit(100e18, user);
        vm.stopPrank();

        vault.pause();
        vm.startPrank(user);
        vm.expectRevert();
        vault.withdraw(10e18, user, user);
        vm.stopPrank();

        vault.unpause();
        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(user);
        vault.withdraw(10e18, user, user);
        vm.stopPrank();
    }

    function testPreviewFunctions() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 1000e18);
        vault.deposit(1000e18, user);

        assertEq(vault.previewDeposit(100e18), 100e18 * 1000);
        assertEq(vault.previewWithdraw(100e18), 100e18 * 1000);
        assertEq(vault.previewRedeem(100e18), 100e18 / 1000);
        assertEq(vault.previewMint(100e18), 100e18 / 1000);
        vm.stopPrank();
    }
}