// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {HalalVault} from "../src/HalalVault.sol";
import {StrategyRouter} from "../src/StrategyRouter.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {ReserveStrategy} from "../src/strategies/ReserveStrategy.sol";
import {UniswapV2Strategy} from "../src/strategies/UniswapV2Strategy.sol";

// ─────────────────────────────────────────────────────────────────────────────
// SetupStrategies — post-deploy script for adding yield strategies.
//
// Run AFTER Deploy.s.sol. Requires MANAGER_ROLE on vault and router.
//
// Strategy allocation:
//
//   Mode A — Reserve only (no AMM pair available):
//     ReserveStrategy  100% (10000 bps) — liquid KGST buffer
//
//   Mode B — KGST/DEEN (primary halal strategy, DEFAULT):
//     ReserveStrategy   20% ( 2000 bps) — instant withdrawal buffer
//     UniswapV2Strategy 80% ( 8000 bps) — KGST/DEEN liquidity, earns trading fees
//
//     DEEN = Islamic Gold Token by HAQQ Network
//     1 DEEN = 1 gram of physical gold, stored in Brinks Dubai vaults
//     Each token linked to a specific bar serial number
//     Shariah-certified — fatwa issued by HAQQ Shariah Advisory Board
//     1% of every DEEN sale goes to charity (built-in Zakat)
//
//   Mode C — KGST/DEEN + KGST/USDC (diversified):
//     ReserveStrategy        10% (1000 bps)
//     UniswapV2Strategy DEEN 70% (7000 bps) — gold pair, primary yield
//     UniswapV2Strategy USDC 20% (2000 bps) — stable pair, lower IL
//
// Set env vars to control which mode runs (see .env.example).
// ─────────────────────────────────────────────────────────────────────────────

contract SetupStrategiesScript is Script {

    // ── State vars avoid stack pressure ──────────────────────────────────
    address vault;
    address router;
    address feeDistributor;
    address kgst;

    address deenToken;
    address deenPair;
    address uniswapRouter;
    address paxgToken;
    address paxgPair;
    address usdcToken;
    address usdcPair;

    bool hasDeen;
    bool hasPaxg;
    bool hasUsdc;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        _loadEnv();
        _logMode();

        vm.startBroadcast(deployerPrivateKey);
        _setupStrategies();
        vm.stopBroadcast();

        _printSummary();
    }

    function _loadEnv() internal {
        vault          = vm.envAddress("VAULT_ADDRESS");
        router         = vm.envAddress("ROUTER_ADDRESS");
        feeDistributor = vm.envAddress("FEE_DISTRIBUTOR_ADDRESS");
        kgst           = vm.envAddress("KGST_ADDRESS");

        deenToken     = vm.envOr("DEEN_TOKEN_ADDRESS",        address(0));
        deenPair      = vm.envOr("KGST_DEEN_PAIR_ADDRESS",    address(0));
        uniswapRouter = vm.envOr("UNISWAP_V2_ROUTER_ADDRESS", address(0));
        paxgToken     = vm.envOr("PAXG_TOKEN_ADDRESS",        address(0));
        paxgPair      = vm.envOr("KGST_PAXG_PAIR_ADDRESS",    address(0));
        usdcToken     = vm.envOr("USDC_TOKEN_ADDRESS",        address(0));
        usdcPair      = vm.envOr("KGST_USDC_PAIR_ADDRESS",    address(0));

        require(vault          != address(0), "VAULT_ADDRESS not set");
        require(router         != address(0), "ROUTER_ADDRESS not set");
        require(feeDistributor != address(0), "FEE_DISTRIBUTOR_ADDRESS not set");
        require(kgst           != address(0), "KGST_ADDRESS not set");

        hasDeen = (deenToken != address(0)) && (deenPair != address(0)) && (uniswapRouter != address(0));
        hasPaxg = hasDeen && (paxgToken != address(0)) && (paxgPair != address(0));
        hasUsdc = hasDeen && (usdcToken != address(0)) && (usdcPair != address(0));
    }

    function _logMode() internal view {
        if (hasPaxg && hasUsdc)      console.log("Mode D: Reserve 10% + DEEN 50% + PAXG 20% + USDC 20%");
        else if (hasPaxg)            console.log("Mode C: Reserve 10% + DEEN 60% + PAXG 30%");
        else if (hasUsdc)            console.log("Mode B+: Reserve 10% + DEEN 70% + USDC 20%");
        else if (hasDeen)            console.log("Mode B: Reserve 20% + DEEN 80% (Islamic gold)");
        else                         console.log("Mode A: Reserve 100% (no AMM pair configured)");
    }

    function _setupStrategies() internal {
        StrategyRouter routerContract = StrategyRouter(router);

        _deployReserve(routerContract);
        if (hasDeen) _deployDeen(routerContract);
        if (hasPaxg) _deployPaxg(routerContract);
        if (hasUsdc) _deployUsdc(routerContract);

        require(routerContract.totalTargetBps() == 10000, "SetupStrategies: BPS not fully allocated");
        HalalVault(vault).setStrategyRouter(router);
    }

    function _deployReserve(StrategyRouter routerContract) internal {
        uint256 reserveBps;
        if (hasPaxg && hasUsdc) reserveBps = 1000;
        else if (hasPaxg)       reserveBps = 1000;
        else if (hasUsdc)       reserveBps = 1000;
        else if (hasDeen)       reserveBps = 2000;
        else                    reserveBps = 10000;

        ReserveStrategy reserve = new ReserveStrategy(kgst);
        reserve.grantRole(reserve.VAULT_ROLE(), router);
        routerContract.addStrategy(address(reserve), reserveBps);
        console.log("ReserveStrategy:        ", address(reserve));
        console.log("  Allocation:            ", reserveBps, "bps");
    }

    function _deployDeen(StrategyRouter routerContract) internal {
        uint256 deenBps;
        if (hasPaxg && hasUsdc) deenBps = 5000;
        else if (hasPaxg)       deenBps = 6000;
        else if (hasUsdc)       deenBps = 7000;
        else                    deenBps = 8000;

        UniswapV2Strategy deenStrategy = new UniswapV2Strategy(
            kgst, deenToken, deenPair, uniswapRouter, feeDistributor,
            false // DEEN is standard ERC20, no transfer fee
        );
        deenStrategy.grantRole(deenStrategy.VAULT_ROLE(), router);
        routerContract.addStrategy(address(deenStrategy), deenBps);
        FeeDistributor(feeDistributor).grantRole(
            FeeDistributor(feeDistributor).STRATEGY_ROLE(),
            address(deenStrategy)
        );
        console.log("UniswapV2Strategy DEEN: ", address(deenStrategy));
        console.log("  Pair:                  KGST/DEEN (1 DEEN = 1g gold, Brinks Dubai)");
        console.log("  Allocation:            ", deenBps, "bps");
    }

    function _deployPaxg(StrategyRouter routerContract) internal {
        uint256 paxgBps = hasUsdc ? 2000 : 3000;

        UniswapV2Strategy paxgStrategy = new UniswapV2Strategy(
            kgst, paxgToken, paxgPair, uniswapRouter, feeDistributor,
            true // PAXG is fee-on-transfer — critical flag!
        );
        paxgStrategy.grantRole(paxgStrategy.VAULT_ROLE(), router);
        routerContract.addStrategy(address(paxgStrategy), paxgBps);
        FeeDistributor(feeDistributor).grantRole(
            FeeDistributor(feeDistributor).STRATEGY_ROLE(),
            address(paxgStrategy)
        );
        console.log("UniswapV2Strategy PAXG: ", address(paxgStrategy));
        console.log("  Pair:                  KGST/PAXG (London gold, fee-on-transfer)");
        console.log("  Allocation:            ", paxgBps, "bps");
    }

    function _deployUsdc(StrategyRouter routerContract) internal {
        UniswapV2Strategy usdcStrategy = new UniswapV2Strategy(
            kgst, usdcToken, usdcPair, uniswapRouter, feeDistributor,
            false // USDC is standard ERC20, no transfer fee
        );
        usdcStrategy.grantRole(usdcStrategy.VAULT_ROLE(), router);
        routerContract.addStrategy(address(usdcStrategy), 2000);
        FeeDistributor(feeDistributor).grantRole(
            FeeDistributor(feeDistributor).STRATEGY_ROLE(),
            address(usdcStrategy)
        );
        console.log("UniswapV2Strategy USDC: ", address(usdcStrategy));
        console.log("  Pair:                  KGST/USDC (stable)");
        console.log("  Allocation:            2000 bps");
    }

    function _printSummary() internal view {
        console.log("=== Strategies Configured ===");
        console.log("Total BPS: ", StrategyRouter(router).totalTargetBps());
        console.log("Next: verify contracts, set trusted bridge sources, test deposit");
    }
}
