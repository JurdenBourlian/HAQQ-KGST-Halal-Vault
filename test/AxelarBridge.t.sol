// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AxelarBridgeReceiver.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockHalalVault.sol";
import "./mocks/MockAxelarGateway.sol";

contract AxelarBridgeTest is Test {
    AxelarBridgeReceiver public bridge;
    MockAxelarGateway public gateway;
    MockAxelarGasService public gasService;
    MockERC20 public kgst;
    MockHalalVault public vault;
    address public admin = address(this);
    address public user = address(0x5678);

    function setUp() public {
        kgst = new MockERC20("KGST", "KGST", 18);
        vault = new MockHalalVault(kgst);
        gateway = new MockAxelarGateway();
        gasService = new MockAxelarGasService();
        bridge = new AxelarBridgeReceiver(
            address(gateway),
            address(gasService),
            address(kgst),
            address(vault)
        );
        bridge.grantRole(bridge.BRIDGE_ADMIN_ROLE(), admin);
        bridge.grantRole(bridge.GUARDIAN_ROLE(), admin);
        bridge.setTrustedSource("BNB Chain", "1234567890123456789012345678901234567890");
        kgst.mint(address(bridge), 1_000_000e18);
    }

    function testExecuteUnauthorizedSource() public {
        bytes memory payload = abi.encode(user, 50e18, true, uint64(1));
        vm.expectRevert(abi.encodeWithSelector(
            AxelarBridgeReceiver.UnauthorizedSource.selector,
            "BNB Chain",
            "0000000000000000000000000000000000000000"
        ));
        gateway.simulateExecute(address(bridge), "BNB Chain", "0000000000000000000000000000000000000000", payload);
    }

    function testReplayProtection() public {
        bytes memory payload = abi.encode(user, uint256(75e18), true, uint64(1));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);

        bytes32 expectedHash = keccak256(abi.encodePacked(
            "BNB Chain",
            "1234567890123456789012345678901234567890",
            user,
            uint256(75e18),
            true,
            uint64(1),
            block.chainid,
            block.number
        ));

        vm.expectRevert(abi.encodeWithSelector(
            AxelarBridgeReceiver.MessageAlreadyProcessed.selector,
            expectedHash
        ));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);
    }

    function testReplayProtectionDifferentBlock() public {
        bytes memory payload = abi.encode(user, uint256(75e18), true, uint64(1));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);

        vm.roll(block.number + 1);
        
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);
        
        assertEq(vault.balanceOf(user), 150e18);
    }

    function testTimeWindowRateLimiting() public {
        bridge.setRateLimits(100e18, 50e18);

        bytes memory payload1 = abi.encode(user, 60e18, true, uint64(1));
        vm.expectRevert(abi.encodeWithSelector(
            AxelarBridgeReceiver.UserRateLimitExceeded.selector,
            user,
            60e18,
            50e18
        ));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload1);

        bytes memory payload2 = abi.encode(user, 40e18, true, uint64(1));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload2);

        bytes memory payload3 = abi.encode(user, 20e18, true, uint64(2));
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(
            AxelarBridgeReceiver.UserRateLimitExceeded.selector,
            user,
            20e18,
            10e18
        ));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload3);
    }

    function testTimeWindowReset() public {
        bridge.setRateLimits(100e18, 50e18);

        bytes memory payload1 = abi.encode(user, 50e18, true, uint64(1));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload1);

        vm.warp(block.timestamp + 1 hours + 1);

        bytes memory payload2 = abi.encode(user, 50e18, true, uint64(2));
        vm.roll(block.number + 1);
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload2);

        assertEq(vault.balanceOf(user), 100e18);
    }

    function testAutoDepositFalse() public {
        bytes memory payload = abi.encode(user, 200e18, false, uint64(1));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);
        assertEq(kgst.balanceOf(user), 200e18);
        assertEq(vault.balanceOf(user), 0);
    }

    event BridgeReceived(string indexed sourceChain, address indexed recipient, uint256 amount, bool autoDeposit, uint64 nonce);

    function testExecuteValidMessage() public {
        bytes memory payload = abi.encode(user, 100e18, true, uint64(1));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeReceived("BNB Chain", user, 100e18, true, 1);
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);
        assertEq(vault.balanceOf(user), 100e18);
    }

    function testPause() public {
        bridge.pause();
        bytes memory payload = abi.encode(user, 50e18, true, uint64(1));
        vm.expectRevert(bytes("Pausable: paused"));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);

        bridge.unpause();
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);
        assertEq(vault.balanceOf(user), 50e18);
    }

    function testGetRateLimitStatus() public {
        bridge.setRateLimits(500e18, 100e18);
        bytes memory payload = abi.encode(user, uint256(75e18), true, uint64(1));
        gateway.simulateExecute(address(bridge), "BNB Chain", "1234567890123456789012345678901234567890", payload);

        (uint256 globalUsed, uint256 globalLimit, uint256 userUsed, uint256 userLimit, uint256 remaining) =
            bridge.getRateLimitStatus(user);
        assertEq(globalUsed, 75e18);
        assertEq(globalLimit, 500e18);
        assertEq(userUsed, 75e18);
        assertEq(userLimit, 100e18);
        assertEq(remaining, 425e18);
    }

    function testFlexibleAddressValidation() public {
        bridge.setTrustedSource("Cosmos", "cosmos1abcdefghijklmnopqrstuvwxyz1234567890");
        
        bytes memory payload = abi.encode(user, 100e18, true, uint64(1));
        gateway.simulateExecute(address(bridge), "Cosmos", "cosmos1abcdefghijklmnopqrstuvwxyz1234567890", payload);
        assertEq(vault.balanceOf(user), 100e18);
    }
}