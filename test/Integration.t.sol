// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HalalVault.sol";
import "../src/ShariahGuard.sol";
import "../src/StrategyRouter.sol";
import "../src/strategies/ReserveStrategy.sol";
import "../src/FeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockShariahOracle.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Integration.t.sol — end-to-end tests for the full protocol stack.
//
// Updated for FeeDistributor v2 with immutable founder share.
// ─────────────────────────────────────────────────────────────────────────────

contract IntegrationTest is Test {
    HalalVault      public vault;
    ShariahGuard    public guard;
    StrategyRouter  public router;
    ReserveStrategy public reserve;
    FeeDistributor  public feeDistributor;
    MockERC20       public kgst;

    address public user    = address(0x1234);
    address public admin   = address(this);
    address public founder = makeAddr("founder"); // immutable pension address

    function setUp() public {
        kgst   = new MockERC20("KGST", "KGST", 18);
        guard  = new ShariahGuard(address(0));
        vault  = new HalalVault(IERC20(address(kgst)), address(guard), "Halal Vault", "hvKGST");
        router = new StrategyRouter(address(kgst), address(vault));

        // FeeDistributor v2: requires founder address
        feeDistributor = new FeeDistributor(address(kgst), founder);

        // Set recipients for remaining 80% (8000 bps)
        FeeDistributor.Recipient[] memory recipients = new FeeDistributor.Recipient[](2);
        recipients[0] = FeeDistributor.Recipient({ account: makeAddr("team"),     shareBps: 4000 });
        recipients[1] = FeeDistributor.Recipient({ account: makeAddr("protocol"), shareBps: 4000 });
        feeDistributor.setRecipients(recipients);

        reserve = new ReserveStrategy(address(kgst));

        vault.grantRole(vault.MANAGER_ROLE(),           admin);
        router.grantRole(router.MANAGER_ROLE(),         admin);
        reserve.grantRole(reserve.VAULT_ROLE(),         address(router));
        feeDistributor.grantRole(feeDistributor.STRATEGY_ROLE(), address(reserve));

        vault.setStrategyRouter(address(router));
        router.addStrategy(address(reserve), 10000);

        kgst.mint(user, 10_000e18);
    }

    // ── Core flow ─────────────────────────────────────────────────────────────

    function testFullDepositWithdrawFlow() public {
        // HalalVault: VIRTUAL_SHARES=1000, VIRTUAL_ASSETS=1
        // deposit(assets) returns shares = assets * 1000 (at genesis)
        // withdraw(assets) returns shares BURNED (ERC4626 standard)
        // redeem(shares) returns assets received
        //
        // IMPORTANT: updateSnapshot modifier runs BEFORE the deposit body (_;  is last),
        // so tvlSnapshot is taken when totalAssets()==0. _updateWithdrawalLimit therefore
        // always falls back to live totalAssets(), which shrinks after each withdrawal.
        // Daily limit = 10% of live totalAssets() at the moment of each withdrawal check.
        uint256 VS = 1000;

        vm.startPrank(user);
        kgst.approve(address(vault), 1000e18);
        uint256 sharesMinted = vault.deposit(1000e18, user);
        assertEq(sharesMinted, 1000e18 * VS);
        assertEq(vault.balanceOf(user), 1000e18 * VS);
        assertEq(vault.totalAssets(), 1000e18);

        // Wait for deposit lock (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        // withdraw(90e18): live TVL=1000e18, limit=100e18, withdrawn=0 → ok
        // Returns shares burned = 90e18 * VS
        uint256 sharesBurned = vault.withdraw(90e18, user, user);
        assertEq(sharesBurned, 90e18 * VS);
        assertEq(kgst.balanceOf(user), 9090e18);
        assertEq(vault.totalAssets(), 910e18);

        // After withdraw(90e18): withdrawnThisPeriod=90e18
        // redeem would need live TVL=910e18 → limit=91e18, but 90+10=100 > 91 → reverts.
        // So we move to the next day to reset the counter.
        vm.warp(block.timestamp + 1 days);

        // redeem(10e18 * VS shares) on a fresh day: live TVL=910e18, limit=91e18 → ok
        uint256 assetsReceived = vault.redeem(10e18 * VS, user, user);
        assertEq(assetsReceived, 10e18);
        assertEq(kgst.balanceOf(user), 9100e18);
        assertEq(vault.totalAssets(), 900e18);

        // Second deposit — test deposit lock
        kgst.approve(address(vault), 100e18);
        vault.deposit(100e18, user);

        vm.expectRevert();
        vault.withdraw(50e18, user, user);

        vm.warp(block.timestamp + 1 hours + 1);
        // live TVL=1000e18, limit=100e18, withdrawn=0 → 50e18 ok
        vault.withdraw(50e18, user, user);

        vm.stopPrank();
    }

    function testStrategyAllocation() public {
        vm.startPrank(user);
        kgst.approve(address(vault), 5000e18);
        vault.deposit(5000e18, user);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 5000e18);
        assertEq(reserve.totalValue(), 0);
    }

    function testWithdrawalLimitEnforcement() public {
        kgst.mint(user, 10_000e18);
        vm.startPrank(user);
        kgst.approve(address(vault), 20_000e18);
        vault.deposit(20_000e18, user);

        vm.warp(block.timestamp + 1 hours);

        uint256 max = vault.maxWithdraw(user);
        assertEq(max, 2000e18);

        vault.withdraw(max, user, user);
        assertEq(vault.maxWithdraw(user), 0);

        vm.expectRevert(
            abi.encodeWithSelector(HalalVault.WithdrawalLimitExceeded.selector, 100e18, 0)
        );
        vault.withdraw(100e18, user, user);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.maxWithdraw(user), 1800e18);
        vm.stopPrank();
    }

    // ── FeeDistributor v2 — founder integration ───────────────────────────────

    function testFeeDistribution_founderAlwaysGets20Percent() public {
        kgst.mint(address(feeDistributor), 1000e18);
        feeDistributor.distribute();

        // Founder: 20% = 200
        assertEq(feeDistributor.pendingFees(founder), 200e18);

        // team + protocol split 800 equally (4000/8000 each = 50%)
        assertEq(feeDistributor.pendingFees(makeAddr("team")),     400e18);
        assertEq(feeDistributor.pendingFees(makeAddr("protocol")), 400e18);
    }

    function testFeeDistribution_founderCanClaim() public {
        kgst.mint(address(feeDistributor), 1000e18);
        feeDistributor.distribute();

        vm.prank(founder);
        feeDistributor.claimFees();

        assertEq(kgst.balanceOf(founder), 200e18);
        assertEq(feeDistributor.pendingFees(founder), 0);
    }

    function testFeeDistribution_founderShareSurvivesRecipientChange() public {
        // Replace all recipients mid-protocol
        address newTeam = makeAddr("newTeam");
        FeeDistributor.Recipient[] memory fresh = new FeeDistributor.Recipient[](1);
        fresh[0] = FeeDistributor.Recipient({ account: newTeam, shareBps: 8000 });
        feeDistributor.setRecipients(fresh);

        kgst.mint(address(feeDistributor), 500e18);
        feeDistributor.distribute();

        // Founder still gets 20% despite team change
        assertEq(feeDistributor.pendingFees(founder), 100e18);
        assertEq(feeDistributor.pendingFees(newTeam), 400e18);
    }

    function testFeeDistribution_pullPattern() public {
        address recipient1 = makeAddr("team");
        address recipient2 = makeAddr("protocol");

        kgst.mint(address(feeDistributor), 1000e18);
        feeDistributor.distribute();

        // Balances zero before claim
        assertEq(kgst.balanceOf(recipient1), 0);
        assertEq(kgst.balanceOf(recipient2), 0);

        vm.prank(recipient1);
        feeDistributor.claimFees();
        assertEq(kgst.balanceOf(recipient1), 400e18);

        vm.prank(recipient2);
        feeDistributor.claimFees();
        assertEq(kgst.balanceOf(recipient2), 400e18);

        vm.prank(founder);
        feeDistributor.claimFees();
        assertEq(kgst.balanceOf(founder), 200e18);

        // Distributor empty after all claims
        assertEq(kgst.balanceOf(address(feeDistributor)), 0);
    }

    // ── Regional compliance ───────────────────────────────────────────────────

    function testRegionalComplianceFlow() public {
        MockShariahOracle regional = new MockShariahOracle(true);
        bytes32 kgRegion = keccak256("KG");
        guard.setRegionalOracle(kgRegion, address(regional));

        vm.startPrank(user);
        kgst.approve(address(vault), 1500e18);
        uint256 shares = vault.depositWithRegion(1500e18, user, kgRegion);
        assertEq(shares, 1500e18 * 1000);
        vm.stopPrank();
    }

    // ── Bridge ────────────────────────────────────────────────────────────────

    function testBridgeDepositIntegration() public {
        vault.grantRole(vault.BRIDGE_ROLE(), admin);
        kgst.mint(address(this), 2500e18);
        kgst.approve(address(vault), 2500e18);
        vault.bridgeDeposit(2500e18, user);
        assertGt(vault.balanceOf(user), 0);
        assertEq(vault.totalAssets(), 2500e18);
    }

    function testBridgeDepositShariahCheck() public {
        MockShariahOracle rejecting = new MockShariahOracle(false);
        guard.setGlobalOracle(address(rejecting));

        vault.grantRole(vault.BRIDGE_ROLE(), admin);
        kgst.mint(address(this), 100e18);
        kgst.approve(address(vault), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                ShariahGuard.ShariahViolation.selector,
                "global-override"
            )
        );
        vault.bridgeDeposit(100e18, user);
    }

    // ── Emergency ────────────────────────────────────────────────────────────

    function testEmergencyPauseAllComponents() public {
        vault.grantRole(vault.GUARDIAN_ROLE(),   admin);
        router.grantRole(router.GUARDIAN_ROLE(), admin);

        vm.startPrank(user);
        kgst.approve(address(vault), 1000e18);
        vault.deposit(1000e18, user);
        vm.stopPrank();

        vault.pause();
        router.pauseStrategy(0, true);

        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(user);
        vm.expectRevert();
        vault.withdraw(100e18, user, user);
        vm.stopPrank();
    }

    // ── Deposit lock ──────────────────────────────────────────────────────────

    function testDepositLockPreventsFrontRun() public {
        // Live TVL-based limit: 10% of current totalAssets() = 100e18 after deposit(1000e18).
        // Withdrawals > 100e18 always revert regardless of lock timing.
        vm.startPrank(user);
        kgst.approve(address(vault), 2000e18);
        vault.deposit(1000e18, user);

        // Immediately after deposit: locked (< 1 hour)
        vm.expectRevert();
        vault.withdraw(50e18, user, user);

        vm.warp(block.timestamp + 30 minutes);
        // Still locked
        vm.expectRevert();
        vault.withdraw(50e18, user, user);

        vm.warp(block.timestamp + 31 minutes);
        // Lock expired, live TVL=1000e18, limit=100e18, withdraw 50e18 → ok
        vault.withdraw(50e18, user, user);
        vm.stopPrank();
    }

    // ── Multi-user scenario ───────────────────────────────────────────────────

    function testMultipleUsers_founderEarnsFromAll() public {
        address user2 = makeAddr("user2");
        kgst.mint(user2, 5000e18);

        // Both users deposit
        vm.startPrank(user);
        kgst.approve(address(vault), 1000e18);
        vault.deposit(1000e18, user);
        vm.stopPrank();

        vm.startPrank(user2);
        kgst.approve(address(vault), 2000e18);
        vault.deposit(2000e18, user2);
        vm.stopPrank();

        // Protocol earns fees (simulate by sending to distributor)
        kgst.mint(address(feeDistributor), 300e18);
        feeDistributor.distribute();

        // Founder always gets 20% regardless of how many users
        assertEq(feeDistributor.pendingFees(founder), 60e18); // 300 * 20%
    }
}






