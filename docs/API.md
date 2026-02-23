# API Reference

> **Testnet Deployment (HAQQ testedge2, Chain 54211)** — All contracts verified on [HAQQ Explorer](https://explorer.testedge2.haqq.network) via Blockscout.
> EVM: `paris` · Solc: `0.8.20` · Optimizer: `200 runs`


## HalalVault
**Testnet Address (HAQQ testedge2):** [`0x5c51760B1A4AbFF820A81f90D210167d2Aa69D68`](https://explorer.testedge2.haqq.network/address/0x5c51760B1A4AbFF820A81f90D210167d2Aa69D68)

### Constants
| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_WITHDRAWAL_PERCENT` | 1000 bps (10%) | Maximum withdrawal as a percentage of total vault assets per transaction |

### Read Functions
- `totalAssets() → uint256`  
  Returns the total amount of underlying KGST managed by the vault. Includes vault's own KGST balance plus all strategy values.
- `currentNAV() → uint256`  
  Returns the current NAV per hvKGST share, scaled by 1e18.  
  `1e18 = 1.0` (initial NAV)  
  `1.1e18 = 1.1` (10% gain)
- `convertToShares(uint256 assets) → uint256`  
  Returns the number of hvKGST shares equivalent to assets KGST at current NAV.
- `convertToAssets(uint256 shares) → uint256`  
  Returns the amount of KGST redeemable for shares hvKGST at current NAV.
- `previewDeposit(uint256 assets) → uint256`  
  Simulates a deposit without state change. Returns shares that would be minted.
- `previewWithdraw(uint256 assets) → uint256`  
  Simulates a withdrawal. Returns shares that would be burned.
- `previewRedeem(uint256 shares) → uint256`  
  Simulates redemption. Returns KGST that would be returned.
- `maxDeposit(address receiver) → uint256`  
  Returns the maximum deposit allowed. Returns `type(uint256).max` if no cap.
- `balanceOf(address account) → uint256`  
  Returns the hvKGST share balance of account.

### Write Functions
- `deposit(uint256 assets, address receiver) → uint256 shares`  
  Deposits assets KGST and mints hvKGST shares to receiver.  
  **Requirements:**  
  - Caller must approve the vault to spend at least assets KGST.  
  - `ShariahGuard.checkCompliance(msg.sender, bytes32(0), assets)` must pass.  
  - Vault must not be paused.  
  **Emits:** `Deposit(caller, receiver, assets, shares)`
- `depositWithRegion(uint256 assets, address receiver, bytes32 regionId) → uint256 shares`  
  Deposits with an additional jurisdictional compliance check.  
  **Requirements:** Same as deposit, but checks against the specified regional oracle.
- `mint(uint256 shares, address receiver) → uint256 assets`  
  Mints exactly shares hvKGST to receiver, pulling the required KGST from the caller.  
  **Requirements:** Same as deposit.
- `withdraw(uint256 assets, address receiver, address owner) → uint256 shares`  
  Withdraws assets KGST to receiver by burning shares from owner.  
  If owner != msg.sender, caller must have sufficient allowance.  
  **Note:** Single withdrawal capped at `MAX_WITHDRAWAL_PERCENT` (10%) of total vault assets.  
  **Emits:** `Withdraw(caller, receiver, owner, assets, shares)`
- `redeem(uint256 shares, address receiver, address owner) → uint256 assets`  
  Burns exactly shares from owner and sends KGST to receiver.

### Admin Functions (`MANAGER_ROLE`)
- `setShariahGuard(address newGuard)` — Replaces the ShariahGuard contract.
- `setStrategyRouter(address router)` — Sets or replaces the StrategyRouter.
- `unpause()` — Resumes vault operations after an emergency pause.

### Admin Functions (`GUARDIAN_ROLE`)
- `pause()` — Pauses all deposits and withdrawals.

## ShariahGuard
**Testnet Address (HAQQ testedge2):** [`0x330052857495FF6F1073825cf413fb4cd585d7ec`](https://explorer.testedge2.haqq.network/address/0x330052857495FF6F1073825cf413fb4cd585d7ec)

- `checkCompliance(address user, bytes32 regionId, uint256 amount)`  
  Called internally by the vault. Reverts with `ShariahViolation(string reason)` if non-compliant. If regionId is non-zero, checks the regional oracle first; otherwise falls back to global.
- `wouldBeCompliant(address user, bytes32 regionId, uint256 amount) → (bool ok, string reason)`  
  Preview compliance without reverting.
- `setGlobalOracle(address oracle)` — `ORACLE_ADMIN_ROLE`
- `setRegionalOracle(bytes32 regionId, address oracle)` — `ORACLE_ADMIN_ROLE`
- `setMaxOracleAge(uint256 age)` — `ORACLE_ADMIN_ROLE`

## StrategyRouter
**Testnet Address (HAQQ testedge2):** [`0x178908940AC057A1e5456413437d16E0555Ee68A`](https://explorer.testedge2.haqq.network/address/0x178908940AC057A1e5456413437d16E0555Ee68A)

- `totalValue() → uint256` — Returns the sum of all active strategy values in KGST.
- `addStrategy(address strategy, uint256 targetBps)` — `MANAGER_ROLE`  
  Registers a new strategy with a target allocation in basis points.
- `deactivateStrategy(uint256 index, uint256 redistributeToIndex)` — `MANAGER_ROLE`  
  Marks a strategy inactive. Freed BPS must be redistributed to another active strategy or explicitly idled (using `type(uint256).max`).
- `pauseStrategy(uint256 index, bool paused)` — `GUARDIAN_ROLE`  
  Pauses a specific strategy.
- `withdrawFromStrategies(uint256 amount) → uint256 withdrawn`  
  Called by the vault to pull liquidity from strategies proportionally.

## IStrategy
Every strategy must implement:
- `deposit(uint256 amount) → uint256 shares` — Deposit KGST, receive strategy shares
- `withdraw(uint256 shares) → uint256 amount` — Burn shares, receive KGST
- `totalValue() → uint256 value` — Current KGST value of all holdings
- `emergencyWithdraw(uint256 amount)` — Immediate withdrawal, bypasses normal logic

## AxelarBridgeReceiver
**Testnet Address (HAQQ testedge2):** Not deployed (Axelar gateway not configured on testnet)

- `execute(bytes32 commandId, string sourceChain, string sourceAddress, bytes payload)`  
  Called by the Axelar gateway. Processes an inbound cross-chain deposit.
- `setTrustedSource(string chain, string sourceAddress)` — `BRIDGE_ADMIN_ROLE`  
  Registers a trusted sender for a given source chain.
- `setRateLimits(uint256 globalLimit, uint256 userLimit)` — `BRIDGE_ADMIN_ROLE`  
  Sets the per-hour inflow caps. Set to 0 to disable rate limiting.

## Events Reference
| Contract | Event | Description |
|----------|-------|-------------|
| HalalVault | `Deposit(caller, receiver, assets, shares)` | Successful deposit |
| HalalVault | `Withdraw(caller, receiver, owner, assets, shares)` | Successful withdrawal |
| HalalVault | `BridgeDeposit(bridge, receiver, assets, shares)` | Bridge-initiated deposit |
| ShariahGuard | `ComplianceResult(user, allowed, source)` | Oracle check result |
| AxelarBridgeReceiver | `BridgeReceived(sourceChain, recipient, amount, autoDeposited, nonce)` | Inbound bridge message processed |
| StrategyRouter | `StrategyAdded(strategy, targetBps)` | New strategy registered |
| FeeDistributor | `FeesDistributed(totalAmount, timestamp)` | Fees sent to recipients |

## Error Reference
| Error | Contract | Trigger |
|-------|----------|---------|
| `ShariahViolation(string reason)` | ShariahGuard | Oracle returned false |
| `OracleStale(address oracle, uint256 lastUpdated, uint256 maxAge)` | ShariahGuard | Oracle data too old |
| `UnauthorizedSource(string chain, address sender)` | BridgeReceiver | Untrusted source chain/sender |
| `RateLimitExceeded(uint256 requested, uint256 remaining)` | BridgeReceiver | Hourly volume exceeded |
| `MessageAlreadyProcessed(bytes32 messageHash)` | BridgeReceiver | Replay attack detected |