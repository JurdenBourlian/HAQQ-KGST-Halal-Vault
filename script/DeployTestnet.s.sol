// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {HalalVault} from "../src/HalalVault.sol";
import {ShariahGuard} from "../src/ShariahGuard.sol";
import {StrategyRouter} from "../src/StrategyRouter.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {ReserveStrategy} from "../src/strategies/ReserveStrategy.sol";
import {AxelarBridgeReceiver} from "../src/AxelarBridgeReceiver.sol";

import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockShariahOracle} from "../test/mocks/MockShariahOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployTestnetScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Starting Testnet Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);

        address axelarGateway    = vm.envOr("AXELAR_GATEWAY_TESTNET",     address(0));
        address axelarGasService = vm.envOr("AXELAR_GAS_SERVICE_TESTNET", address(0));

        // On testnet: founder defaults to deployer if not set.
        // In production ALWAYS set FOUNDER_ADDRESS explicitly.
        address founderAddress = vm.envOr("FOUNDER_ADDRESS", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // ── Mocks ─────────────────────────────────────────────────────────────
        MockERC20         kgstToken    = new MockERC20("KGST Token", "KGST", 18);
        MockShariahOracle globalOracle = new MockShariahOracle(true);

        console.log("Mock KGST:  ", address(kgstToken));
        console.log("Mock Oracle:", address(globalOracle));

        // ── Core contracts ────────────────────────────────────────────────────
        ShariahGuard   shariahGuard   = new ShariahGuard(address(globalOracle));
        HalalVault     vault          = new HalalVault(
            IERC20(address(kgstToken)),
            address(shariahGuard),
            "HAQQ KGST Halal Vault",
            "hvKGST"
        );
        StrategyRouter router         = new StrategyRouter(address(kgstToken), address(vault));
        ReserveStrategy reserve       = new ReserveStrategy(address(kgstToken));

        // FeeDistributor — founder address is immutable even on testnet
        FeeDistributor feeDistributor = new FeeDistributor(address(kgstToken), founderAddress);

        console.log("ShariahGuard:    ", address(shariahGuard));
        console.log("HalalVault:      ", address(vault));
        console.log("StrategyRouter:  ", address(router));
        console.log("ReserveStrategy: ", address(reserve));
        console.log("FeeDistributor:  ", address(feeDistributor));
        console.log("  Founder (20%): ", founderAddress);

        // ── Fee recipients (testnet — all point to deployer for simplicity) ───
        // On testnet we use deployer for all recipients so one wallet can test everything.
        // On mainnet each recipient is a separate multisig/address.
        FeeDistributor.Recipient[] memory testRecipients = new FeeDistributor.Recipient[](5);
        testRecipients[0] = FeeDistributor.Recipient({ account: address(1), shareBps: 2500 }); // team
        testRecipients[1] = FeeDistributor.Recipient({ account: address(1), shareBps: 2500 }); // protocol fund
        testRecipients[2] = FeeDistributor.Recipient({ account: address(1), shareBps: 1500 }); // shariah board
        testRecipients[3] = FeeDistributor.Recipient({ account: address(1), shareBps: 1000 }); // charity
        testRecipients[4] = FeeDistributor.Recipient({ account: address(1), shareBps:  500 }); // dao reserve
        // Note: duplicate accounts are fine for testnet — all pending fees accumulate to deployer.
        // On mainnet setRecipients() is called with unique addresses per recipient.
        feeDistributor.setRecipients(testRecipients);
        console.log("FeeDistributor recipients: all pointing to deployer (testnet mode)");

        // ── Roles and wiring ──────────────────────────────────────────────────
        vault.grantRole(vault.MANAGER_ROLE(),                  deployer);
        router.grantRole(router.MANAGER_ROLE(),                deployer);
        reserve.grantRole(reserve.VAULT_ROLE(),                address(router));
        feeDistributor.grantRole(feeDistributor.STRATEGY_ROLE(), address(reserve));

        vault.setStrategyRouter(address(router));
        router.addStrategy(address(reserve), 10000);
        require(router.totalTargetBps() == 10000, "Testnet: BPS not fully allocated");

        // ── Bridge (optional) ─────────────────────────────────────────────────
        if (axelarGateway != address(0) && axelarGasService != address(0)) {
            AxelarBridgeReceiver bridge = new AxelarBridgeReceiver(
                axelarGateway,
                axelarGasService,
                address(kgstToken),
                address(vault)
            );
            bridge.grantRole(bridge.BRIDGE_ADMIN_ROLE(), deployer);
            bridge.grantRole(bridge.OPERATOR_ROLE(),     deployer);
            vault.grantRole(vault.BRIDGE_ROLE(),         address(bridge));
            console.log("BridgeReceiver:  ", address(bridge));
        } else {
            console.log("BridgeReceiver skipped (AXELAR_GATEWAY_TESTNET not set)");
        }

        // ── Mint test tokens to deployer ──────────────────────────────────────
        kgstToken.mint(deployer, 1_000_000 ether);
        console.log("Minted 1,000,000 KGST to deployer for testing");

        vm.stopBroadcast();

        console.log("=== Testnet Deployment Complete ===");
        console.log("Founder immutable share: 20% forever");
        console.log("Test deposit: approve vault then call deposit()");
    }
}
