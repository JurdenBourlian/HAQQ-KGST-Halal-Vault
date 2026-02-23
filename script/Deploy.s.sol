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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployScript is Script {

    // ── Deployed contract references (state vars avoid stack pressure) ────
    ShariahGuard       shariahGuard;
    HalalVault         vault;
    StrategyRouter     router;
    FeeDistributor     feeDistributor;
    ReserveStrategy    reserve;
    AxelarBridgeReceiver bridge;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Starting HAQQ-KGST-Halal-Vault Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        _deployContracts();
        _wireContracts();
        _transferAdmin(deployer);

        vm.stopBroadcast();

        _finalChecks();
        _printSummary();
    }

    function _deployContracts() internal {
        address kgstToken     = vm.envAddress("KGST_TOKEN_ADDRESS");
        address globalOracle  = vm.envAddress("GLOBAL_ORACLE_ADDRESS");
        address founderAddress = vm.envAddress("FOUNDER_ADDRESS");

        require(kgstToken    != address(0), "KGST_TOKEN_ADDRESS not set");
        require(globalOracle != address(0), "GLOBAL_ORACLE_ADDRESS not set");
        require(founderAddress != address(0), "FOUNDER_ADDRESS not set");

        // ShariahGuard
        console.log("Deploying ShariahGuard...");
        shariahGuard = new ShariahGuard(globalOracle);
        shariahGuard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);
        console.log("ShariahGuard:", address(shariahGuard));

        // HalalVault
        console.log("Deploying HalalVault...");
        vault = new HalalVault(
            IERC20(kgstToken),
            address(shariahGuard),
            "HAQQ KGST Halal Vault",
            "hvKGST"
        );
        console.log("HalalVault:", address(vault));

        // StrategyRouter
        console.log("Deploying StrategyRouter...");
        router = new StrategyRouter(kgstToken, address(vault));
        console.log("StrategyRouter:", address(router));

        // FeeDistributor
        console.log("Deploying FeeDistributor...");
        console.log("  Founder (immutable 20%):", founderAddress);
        feeDistributor = new FeeDistributor(kgstToken, founderAddress);
        _configureFeeRecipients();
        console.log("FeeDistributor:", address(feeDistributor));

        // ReserveStrategy
        console.log("Deploying ReserveStrategy...");
        reserve = new ReserveStrategy(kgstToken);
        console.log("ReserveStrategy:", address(reserve));

        // AxelarBridgeReceiver
        console.log("Deploying AxelarBridgeReceiver...");
        bridge = new AxelarBridgeReceiver(
            vm.envAddress("AXELAR_GATEWAY_ADDRESS"),
            vm.envAddress("AXELAR_GAS_SERVICE_ADDRESS"),
            kgstToken,
            address(vault)
        );
        console.log("BridgeReceiver:", address(bridge));
    }

    function _configureFeeRecipients() internal {
        address teamMultisig  = vm.envAddress("TEAM_MULTISIG_ADDRESS");
        address protocolFund  = vm.envAddress("PROTOCOL_FUND_ADDRESS");
        address shariahBoard  = vm.envAddress("SHARIAH_BOARD_ADDRESS");
        address charityAddress = vm.envAddress("CHARITY_ADDRESS");
        address daoReserve    = vm.envAddress("DAO_RESERVE_ADDRESS");

        require(teamMultisig   != address(0), "TEAM_MULTISIG_ADDRESS not set");
        require(protocolFund   != address(0), "PROTOCOL_FUND_ADDRESS not set");
        require(shariahBoard   != address(0), "SHARIAH_BOARD_ADDRESS not set");
        require(charityAddress != address(0), "CHARITY_ADDRESS not set");
        require(daoReserve     != address(0), "DAO_RESERVE_ADDRESS not set");

        // Distribution of remaining 80% (8000 bps):
        //   Team          2500 bps = 20% overall
        //   Protocol Fund 2500 bps = 20% overall
        //   Shariah Board 1500 bps = 15% overall
        //   Charity/Zakat 1000 bps = 10% overall
        //   DAO Reserve    500 bps =  5% overall
        //                 ──────────────────────
        //                 8000 bps ✓
        FeeDistributor.Recipient[] memory r = new FeeDistributor.Recipient[](5);
        r[0] = FeeDistributor.Recipient({ account: teamMultisig,   shareBps: 2500 });
        r[1] = FeeDistributor.Recipient({ account: protocolFund,   shareBps: 2500 });
        r[2] = FeeDistributor.Recipient({ account: shariahBoard,   shareBps: 1500 });
        r[3] = FeeDistributor.Recipient({ account: charityAddress, shareBps: 1000 });
        r[4] = FeeDistributor.Recipient({ account: daoReserve,     shareBps:  500 });
        feeDistributor.setRecipients(r);
        console.log("FeeDistributor recipients configured (8000 bps across 5 recipients)");
    }

    function _wireContracts() internal {
        address guardianMultisig = vm.envAddress("GUARDIAN_MULTISIG_ADDRESS");
        require(guardianMultisig != address(0), "GUARDIAN_MULTISIG_ADDRESS not set");

        console.log("Configuring roles and connections...");

        vault.setStrategyRouter(address(router));
        router.addStrategy(address(reserve), 10000);
        require(router.totalTargetBps() == 10000, "Deploy: BPS not fully allocated");
        console.log("ReserveStrategy registered at 100% BPS");

        vault.grantRole(vault.BRIDGE_ROLE(),   address(bridge));
        vault.grantRole(vault.GUARDIAN_ROLE(), guardianMultisig);

        router.grantRole(router.GUARDIAN_ROLE(), guardianMultisig);
        reserve.grantRole(reserve.VAULT_ROLE(),  address(router));

        bridge.grantRole(bridge.GUARDIAN_ROLE(), guardianMultisig);

        feeDistributor.grantRole(feeDistributor.GUARDIAN_ROLE(),  guardianMultisig);
        feeDistributor.grantRole(feeDistributor.STRATEGY_ROLE(),  address(reserve));
    }

    function _transferAdmin(address deployer) internal {
        address adminMultisig   = vm.envAddress("ADMIN_MULTISIG_ADDRESS");
        address managerMultisig = vm.envAddress("MANAGER_MULTISIG_ADDRESS");

        require(adminMultisig   != address(0), "ADMIN_MULTISIG_ADDRESS not set");
        require(managerMultisig != address(0), "MANAGER_MULTISIG_ADDRESS not set");

        _ensureContract(adminMultisig,   "Admin");
        _ensureContract(managerMultisig, "Manager");
        _ensureContract(vm.envAddress("GUARDIAN_MULTISIG_ADDRESS"), "Guardian");

        console.log("Transferring admin roles to multisigs...");

        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), adminMultisig);
        vault.grantRole(vault.MANAGER_ROLE(),       managerMultisig);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);
        vault.renounceRole(vault.MANAGER_ROLE(),       deployer);

        router.grantRole(router.DEFAULT_ADMIN_ROLE(), adminMultisig);
        router.grantRole(router.MANAGER_ROLE(),       managerMultisig);
        router.renounceRole(router.DEFAULT_ADMIN_ROLE(), deployer);
        router.renounceRole(router.MANAGER_ROLE(),       deployer);

        shariahGuard.grantRole(shariahGuard.DEFAULT_ADMIN_ROLE(), adminMultisig);
        shariahGuard.grantRole(shariahGuard.ORACLE_ADMIN_ROLE(),  managerMultisig);
        shariahGuard.renounceRole(shariahGuard.DEFAULT_ADMIN_ROLE(), deployer);
        shariahGuard.renounceRole(shariahGuard.ORACLE_ADMIN_ROLE(),  deployer);

        feeDistributor.grantRole(feeDistributor.DEFAULT_ADMIN_ROLE(), adminMultisig);
        feeDistributor.grantRole(feeDistributor.FEE_MANAGER_ROLE(),   managerMultisig);
        feeDistributor.renounceRole(feeDistributor.DEFAULT_ADMIN_ROLE(), deployer);
        feeDistributor.renounceRole(feeDistributor.FEE_MANAGER_ROLE(),   deployer);

        bridge.grantRole(bridge.DEFAULT_ADMIN_ROLE(),  adminMultisig);
        bridge.grantRole(bridge.BRIDGE_ADMIN_ROLE(),   managerMultisig);
        bridge.grantRole(bridge.OPERATOR_ROLE(),       managerMultisig);
        bridge.renounceRole(bridge.DEFAULT_ADMIN_ROLE(),  deployer);
        bridge.renounceRole(bridge.BRIDGE_ADMIN_ROLE(),   deployer);
        bridge.renounceRole(bridge.OPERATOR_ROLE(),       deployer);

        reserve.grantRole(reserve.DEFAULT_ADMIN_ROLE(), adminMultisig);
        reserve.grantRole(reserve.MANAGER_ROLE(),       managerMultisig);
        reserve.renounceRole(reserve.DEFAULT_ADMIN_ROLE(), deployer);
        reserve.renounceRole(reserve.MANAGER_ROLE(),       deployer);

        console.log("Deployer roles revoked. Multisigs now control all contracts.");
    }

    function _finalChecks() internal view {
        address kgstToken     = vm.envAddress("KGST_TOKEN_ADDRESS");
        address founderAddress = vm.envAddress("FOUNDER_ADDRESS");

        require(vault.totalAssets() == 0,                         "Vault should be empty");
        require(vault.totalSupply() == 0,                         "No shares should exist");
        require(IERC20(kgstToken).balanceOf(address(vault)) == 0, "No tokens in vault");
        require(
            shariahGuard.oraclePriority() == ShariahGuard.OraclePriority.GLOBAL_OVERRIDE,
            "Wrong oracle priority mode"
        );
        require(
            feeDistributor.founder() == founderAddress,
            "Founder address mismatch"
        );
    }

    function _printSummary() internal view {
        console.log("=== Deployment Complete ===");
        console.log("HalalVault:       ", address(vault));
        console.log("ShariahGuard:     ", address(shariahGuard));
        console.log("  Mode: GLOBAL_OVERRIDE");
        console.log("StrategyRouter:   ", address(router));
        console.log("FeeDistributor:   ", address(feeDistributor));
        console.log("  Founder (20%):  ", vm.envAddress("FOUNDER_ADDRESS"));
        console.log("ReserveStrategy:  ", address(reserve));
        console.log("BridgeReceiver:   ", address(bridge));
        console.log("KGST Token:       ", vm.envAddress("KGST_TOKEN_ADDRESS"));
        console.log("Global Oracle:    ", vm.envAddress("GLOBAL_ORACLE_ADDRESS"));
        console.log("Admin Multisig:   ", vm.envAddress("ADMIN_MULTISIG_ADDRESS"));
    }

    function _ensureContract(address addr, string memory name) internal view {
        uint256 size;
        assembly { size := extcodesize(addr) }
        require(size > 0, string(abi.encodePacked(name, " must be contract")));
    }
}
