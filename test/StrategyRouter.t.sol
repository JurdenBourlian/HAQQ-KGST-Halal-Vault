// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StrategyRouter.sol";
import "./mocks/MockERC20.sol";

contract StrategyRouterTest is Test {
    StrategyRouter public router;
    MockERC20 public kgst;
    address public vault = address(0x9999);
    address public admin = address(this);

    function setUp() public {
        kgst = new MockERC20("KGST", "KGST", 18);
        router = new StrategyRouter(address(kgst), vault);
        router.grantRole(router.MANAGER_ROLE(), admin);
    }

    function testAddStrategy() public {
        TestStrategy strat = new TestStrategy(address(kgst));
        kgst.mint(address(strat), 100e18);
        router.addStrategy(address(strat), 5000);
        (address s, uint256 bps, bool active, bool paused, uint256 value) =
            router.getStrategyInfo(0);
        assertEq(s, address(strat));
        assertEq(bps, 5000);
        assertTrue(active);
        assertFalse(paused);
        assertEq(value, 100e18);
    }

    function testTotalBpsValidation() public {
        TestStrategy s1 = new TestStrategy(address(kgst));
        TestStrategy s2 = new TestStrategy(address(kgst));
        router.addStrategy(address(s1), 6000);
        router.addStrategy(address(s2), 4000);
        TestStrategy s3 = new TestStrategy(address(kgst));
        vm.expectRevert(
            abi.encodeWithSelector(StrategyRouter.TotalBpsExceeds100Percent.selector, 10001)
        );
        router.addStrategy(address(s3), 1);
    }

    function testDeactivateAndRedistribute() public {
        TestStrategy s1 = new TestStrategy(address(kgst));
        TestStrategy s2 = new TestStrategy(address(kgst));
        router.addStrategy(address(s1), 6000);
        router.addStrategy(address(s2), 4000);

        router.deactivateStrategy(0, 1);
        (, uint256 bps1, , , ) = router.getStrategyInfo(0);
        (, uint256 bps2, , , ) = router.getStrategyInfo(1);
        assertEq(bps1, 0);
        assertEq(bps2, 10000);
    }

    function testDeactivateWithoutRedistribution() public {
        TestStrategy s1 = new TestStrategy(address(kgst));
        TestStrategy s2 = new TestStrategy(address(kgst));
        router.addStrategy(address(s1), 5000);
        router.addStrategy(address(s2), 5000);

        router.deactivateStrategy(0, type(uint256).max);
        assertEq(router.totalTargetBps(), 5000);
    }

    function testReactivateStrategyCorrect() public {
        TestStrategy s1 = new TestStrategy(address(kgst));
        TestStrategy s2 = new TestStrategy(address(kgst));
        router.addStrategy(address(s1), 7000);
        router.addStrategy(address(s2), 3000);
        router.deactivateStrategy(1, type(uint256).max);
        assertEq(router.totalTargetBps(), 7000);

        router.reactivateStrategy(1, 3000);
        (, uint256 bps, bool active, , ) = router.getStrategyInfo(1);
        assertEq(bps, 3000);
        assertTrue(active);
        assertEq(router.totalTargetBps(), 10000);
    }

    function testPauseStrategy() public {
        router.grantRole(router.GUARDIAN_ROLE(), admin);
        TestStrategy s1 = new TestStrategy(address(kgst));
        router.addStrategy(address(s1), 10000);
        router.pauseStrategy(0, true);
        (, , , bool paused, ) = router.getStrategyInfo(0);
        assertTrue(paused);
        assertEq(router.totalTargetBps(), 0);
    }

    function testTotalValue() public {
        TestStrategy s1 = new TestStrategy(address(kgst));
        TestStrategy s2 = new TestStrategy(address(kgst));
        kgst.mint(address(s1), 100e18);
        kgst.mint(address(s2), 100e18);
        router.addStrategy(address(s1), 5000);
        router.addStrategy(address(s2), 5000);
        assertEq(router.totalValue(), 200e18);
    }

    function testWithdrawFromStrategies() public {
        TestStrategy s1 = new TestStrategy(address(kgst));
        TestStrategy s2 = new TestStrategy(address(kgst));
        kgst.mint(address(s1), 100e18);
        kgst.mint(address(s2), 100e18);

        router.addStrategy(address(s1), 5000);
        router.addStrategy(address(s2), 5000);

        vm.expectRevert(abi.encodeWithSelector(StrategyRouter.OnlyVault.selector));
        router.withdrawFromStrategies(50e18);

        vm.prank(vault);
        uint256 withdrawn = router.withdrawFromStrategies(150e18);
        assertEq(withdrawn, 150e18);
        assertEq(kgst.balanceOf(vault), 150e18);
    }

    function testWithdrawTracksActualReceived() public {
        // PartialStrategy always gives 50% of what's requested.
        // The router's first pass requests 100e18 (full balance), gets 50e18.
        // remaining = 50e18 → second pass requests remaining 50e18, gets 25e18.
        // The router keeps trying until remaining == 0 or no more available.
        // Total received = 50 + 25 = 75e18 (router drains strategy progressively).
        //
        // To test that the router correctly tracks *actual* received (not requested),
        // we verify that withdrawn equals what the strategy actually transferred
        // (measured via balance diff), not what was requested.
        PartialStrategy s1 = new PartialStrategy(address(kgst));
        kgst.mint(address(s1), 100e18);

        router.addStrategy(address(s1), 10000);

        vm.prank(vault);
        uint256 withdrawn = router.withdrawFromStrategies(100e18);

        // Router tracks actual received via balance diff — not what was requested.
        // PartialStrategy gives 50% each call:
        //   Pass 1: request 100e18 → gives 50e18  (remaining=50e18)
        //   Pass 2: request 50e18  → gives 25e18  (remaining=25e18)
        // After pass 2 the second loop exhausts available (strategyBalance[0]-strategyWithdrawn[0] = 0)
        // so it stops. Total withdrawn = 75e18.
        assertEq(withdrawn, 75e18);
        assertEq(kgst.balanceOf(vault), 75e18);
        // Strategy still holds 25e18 (was not fully drained due to partial gives)
        assertEq(kgst.balanceOf(address(s1)), 25e18);
    }

    function testInsufficientLiquidity() public {
        // RevertingStrategy: totalValue()>0 but withdraw() always reverts.
        // Router catches the revert via try/catch, withdrawn=0 → revert(amount, 0)
        RevertingStrategy s1 = new RevertingStrategy(address(kgst));
        kgst.mint(address(s1), 100e18);
        router.addStrategy(address(s1), 10000);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyRouter.InsufficientStrategyLiquidity.selector,
                300e18,
                0
            )
        );
        router.withdrawFromStrategies(300e18);
    }
}

contract TestStrategy {
    MockERC20 public immutable token;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function deposit(uint256 amount) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 toSend = amount > bal ? bal : amount;
        if (toSend > 0) {
            token.transfer(msg.sender, toSend);
        }
        return toSend;
    }

    function totalValue() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function emergencyWithdraw(uint256 amount) external {
        uint256 bal = token.balanceOf(address(this));
        uint256 toSend = amount > bal ? bal : amount;
        if (toSend > 0) token.transfer(msg.sender, toSend);
    }
}

contract PartialStrategy {
    MockERC20 public immutable token;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 actualAmount = amount / 2;
        if (actualAmount > 0) {
            token.transfer(msg.sender, actualAmount);
        }
        return actualAmount;
    }

    function totalValue() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function emergencyWithdraw(uint256) external {}
}

contract RevertingStrategy {
    MockERC20 public immutable token;
    constructor(address _token) { token = MockERC20(_token); }
    function withdraw(uint256) external pure returns (uint256) { revert("always reverts"); }
    function totalValue() external view returns (uint256) { return token.balanceOf(address(this)); }
    function emergencyWithdraw(uint256) external {}
}
