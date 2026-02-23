# Architecture

## Overview
HAQQ-KGST-Halal-Vault is a modular, upgradeable yield aggregator built on HAQQ L2. It consists of five on-chain contracts wired together through access-controlled interfaces.

```
┌─────────────────────────────┐
User (HAQQ L2)  ──────►│       HalalVault (ERC-4626)  │
│   contribute / withdraw / NAV  │
└──────────┬──────────────────┘
           │
┌──────────┼───────────────────────────┐
│          │                           │
▼          ▼                           ▼
┌──────────────────┐  ┌──────────────────┐   ┌───────────────────────┐
│  ShariahGuard    │  │  StrategyRouter  │   │  FeeDistributor       │
│  + Oracle(s)     │  │  ├ V2Strategy    │   │  → team, treasury,    │
└──────────────────┘  │  └ ReserveStrat  │   │    shariah board, DAO │
                      └──────────────────┘   └───────────────────────┘
BNB Chain ──► Axelar Network ──► AxelarBridgeReceiver ──► HalalVault
```

## Contract Responsibilities

### HalalVault (`src/HalalVault.sol`)
The central user-facing contract. Implements ERC-4626 (tokenized vault standard).

- `deposit(assets, receiver)` — transfers KGST in, mints hvKGST shares.
- `withdraw(assets, receiver, owner)` — burns hvKGST shares, returns KGST.
- `totalAssets()` — sums vault KGST balance + StrategyRouter.totalValue().
- `currentNAV()` — returns NAV per share scaled to 1e18.

Calls `ShariahGuard.checkCompliance()` before every contribution.

**Roles:**
| Role | Permission |
|------|------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke all roles |
| `MANAGER_ROLE` | Update guard, router, unpause |
| `GUARDIAN_ROLE` | Emergency pause |
| `BRIDGE_ROLE` | Trigger bridge-initiated transfers |

### ShariahGuard (`src/ShariahGuard.sol`)
Pre-transaction compliance firewall.

- Maintains a global oracle (HAQQ Shariah Advisory Board).
- Supports per-jurisdiction oracles keyed by `bytes32 regionId` (e.g., `keccak256("KG")`, `keccak256("UAE")`).
- `checkCompliance(caller, regionId, amount)` — reverts with `ShariahViolation` if non-compliant.

### StrategyRouter (`src/StrategyRouter.sol`)
Manages capital allocation across multiple yield strategies.

- Each `StrategyInfo` records a strategy address, target allocation in bps, and active flag.
- `totalValue()` aggregates `IStrategy.totalValue()` across active strategies.
- `withdrawFromStrategies()` is called by the vault to pull liquidity.
- `deactivateStrategy()` requires explicit BPS redistribution to prevent idle capital.

### Strategies
All strategies implement `IStrategy` (`src/interfaces/IStrategy.sol`):

- **UniswapV2Strategy** — provides liquidity to a v2 AMM pool. Primary pair on testnet: **KGST/DEEN** (Islamic gold). Supports fee-on-transfer tokens via `otherTokenFeeOnTransfer` constructor flag — enabling pairs like KGST/PAXG on mainnet without code changes.
- **UniswapV3Strategy** — concentrated liquidity position with configurable tick range. **⚠️ Scaffold only — not deployed in production.**
- **ReserveStrategy** — liquid KGST buffer, enables instant withdrawals.

**Strategy allocation modes (set via `SetupStrategies.s.sol`):**

| Mode | Allocation | Status |
|------|-----------|--------|
| A — Reserve only | Reserve 100% | Testnet |
| B — DEEN | Reserve 20% + KGST/DEEN 80% | **Testnet (default)** |
| C — DEEN + PAXG | Reserve 10% + KGST/DEEN 60% + KGST/PAXG 30% | Example — mainnet |
| D — DEEN + PAXG (extended) | Reserve 10% + KGST/DEEN 50% + KGST/PAXG 40% | Example — mainnet |

> Modes C and D require KGST/PAXG pool on Ethiq L2. PAXG is natively on Ethereum — bringing it to HAQQ L2 requires a dedicated bridge and formal agreement with Paxos for multi-chain support. New strategies can be added without modifying core contracts — the `StrategyRouter` accepts any address implementing `IStrategy`. All pairs must use Shariah-compliant assets.

### AxelarBridgeReceiver (`src/AxelarBridgeReceiver.sol`)
Handles inbound cross-chain messages from BNB Chain via Axelar GMP.

- Validates the source chain and sender against `trustedSources` mapping.
- Uses nonce-based replay protection to prevent duplicate message attacks.
- Enforces global and per-user rate limits (hourly window).
- Emits `BridgeReceived` and optionally auto-transfers into the vault.

### FeeDistributor (`src/FeeDistributor.sol`)
Splits collected protocol fees. Founder share is **immutable** — hardcoded at deployment.

- `founder` — immutable address set in constructor. Cannot be changed by any role, ever.
- `FOUNDER_SHARE_BPS = 2000` — founder always receives 20% of every `distribute()` call.
- `RECIPIENTS_TOTAL_BPS = 8000` — remaining 80% split among configurable recipients.
- `receiveFee()` — restricted to `STRATEGY_ROLE` to prevent spam.
- `distribute()` — restricted to `FEE_MANAGER_ROLE` to prevent front-running.
- `setRecipients()` — replaces recipient list; shares must sum to **8000 bps** (not 10000).
- `previewDistribution()` — view function showing exact split before executing.

**Fee distribution (default configuration):**

> **Note on BPS accounting:** `FOUNDER_SHARE_BPS` is applied to the full fee amount (base 10000). Configurable recipients split the remaining 8000 bps among themselves (base 8000). The table below shows effective shares of *total* fees.

| Recipient | Effective share of total fees | Recipient BPS (base 8000) | Mutable? |
|-----------|-------------------------------|--------------------------|----------|
| Founder (immutable) | 20% | — (2000 / 10000) | **No** |
| Team | ~20% | 2500 / 8000 | Yes |
| Protocol Fund | ~20% | 2500 / 8000 | Yes |
| Shariah Board | ~12% | 1500 / 8000 | Yes |
| Charity / Zakat | ~8% | 1000 / 8000 | Yes |
| DAO Reserve | ~4% | 500 / 8000 | Yes |

*Configurable recipients must always sum to exactly 8000 bps.*

## Security Model
- **Reentrancy:** All state-modifying vault and strategy functions use `nonReentrant`.
- **Access control:** Role-based via OpenZeppelin AccessControl. No single key has all permissions.
- **Emergency pause:** `GUARDIAN_ROLE` can pause the vault and bridge receiver instantly.
- **Oracle safety:** Staleness checks prevent use of outdated oracle data.
- **Bridge safety:** Untrusted source chains are rejected; replay protection via nonce.
- **Immutable vault in router:** Prevents confused-deputy attacks.
- **Withdrawal limit:** `MAX_WITHDRAWAL_PERCENT = 1000 bps` (10% of vault per transaction) — see `HalalVault.sol`.

## Deployment Checklist
1. Set `FOUNDER_ADDRESS` in `.env` — immutable, back up private key
2. Set `KGST_TOKEN_ADDRESS` and multisig addresses in `.env`
3. Run `Deploy.s.sol` → deploys vault, guard, router, FeeDistributor with founder
4. Run `DeployDEX.s.sol` → deploys Uniswap V2 fork on Ethiq L2, creates KGST/DEEN pool
5. Run `SetupStrategies.s.sol` → deploys and wires strategies (Mode B by default)
6. Set trusted bridge sources via `AxelarBridgeReceiver.setTrustedSource()`
7. Run `forge test --fork-url $RPC_URL` against live state
8. Transfer `DEFAULT_ADMIN_ROLE` to multisig; revoke deployer admin