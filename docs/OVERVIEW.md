# How the Vault Works

## The Problem

Muslim savers have very few options for earning halal yield. Conventional banks offer interest — riba, prohibited under Islamic law. Crypto exchanges offer speculation — gharar, prohibited. The products that do exist are slow, expensive, and hard to access.

## What This Protocol Does

HAQQ-KGST Halal Vault accepts KGST (Kyrgyz Digital Som) and puts it to work in a Shariah-compliant way. The user contributes KGST and receives `hvKGST` — a share token that appreciates as the vault earns yield.

## Where the Yield Comes From

The vault provides liquidity to the KGST/DEEN trading pair on a decentralised exchange. DEEN is a gold-backed token: 1 DEEN = 1 gram of physical gold, custodied in Brinks vaults in Dubai.

When market participants swap between KGST and DEEN, they pay a small fee. That fee is service revenue — distributed proportionally to liquidity providers, including the vault. This is the same principle as a market-maker earning a spread. It is not interest. It is not speculation. It is compensation for providing a useful service.

## Why This Is Halal

| Principle | Requirement | How the vault meets it |
|-----------|-------------|------------------------|
| No riba | No interest or guaranteed return | Yield = trading fees only. No loans, no fixed rate. |
| No gharar | No excessive uncertainty | Assets are physical gold and a state-issued currency. All positions are on-chain and publicly verifiable. |
| No maysir | No gambling or zero-sum speculation | No leverage, no derivatives, no prediction markets. |
| Bay' al-sarf | Immediate settlement in gold trades | All transactions settle on-chain in the same block. |

## The Compliance Firewall

Every contribution passes through `ShariahGuard` — an on-chain contract that queries a Shariah compliance oracle before allowing any transaction. If the oracle returns non-compliant, the transaction reverts. There is no way to bypass this check.

The architecture supports both a global oracle (HAQQ Shariah Advisory Board) and per-jurisdiction oracles for regional Shariah councils. Both must approve for a transaction to proceed.

## What hvKGST Is

`hvKGST` is an ERC-4626 share token. It represents a proportional claim on all assets in the vault. As the vault earns trading fees, the value of each `hvKGST` share increases relative to KGST. There is no fixed return — the yield reflects actual pool activity.

## The Flow

```
User contributes KGST
       ↓
ShariahGuard checks compliance on-chain — reverts if non-compliant
       ↓
HalalVault mints hvKGST shares to user
       ↓
StrategyRouter allocates capital:
  ├── 80% → UniswapV2Strategy (KGST/DEEN pool)
  └── 20% → ReserveStrategy (liquid buffer)
       ↓
KGST/DEEN pool earns trading fees from every swap
       ↓
User withdraws: hvKGST shares burned, KGST + yield returned
```

## Extensibility — More Pairs, No Core Changes

The KGST/DEEN pool is the first pair. It is not the only one the architecture supports.

`StrategyRouter` accepts any address implementing the `IStrategy` interface. Adding a new yield strategy — for example KGST/PAXG (London gold) or any other Shariah-compliant pair — requires deploying a new strategy contract (a configured instance of `UniswapV2Strategy` pointing to the new pool) and registering it with the router. The core contracts — HalalVault, ShariahGuard, FeeDistributor, StrategyRouter — do not need to be modified or redeployed.

Capital allocation across strategies is controlled in basis points (bps). Example configurations:

| Mode | Allocation | Use case |
|------|-----------|----------|
| A — Reserve only | Reserve 100% | Safe default, instant withdrawals |
| B — DEEN | Reserve 20% + KGST/DEEN 80% | **Testnet default** |
| C — DEEN + PAXG | Reserve 10% + KGST/DEEN 60% + KGST/PAXG 30% | Mainnet example |
| D — DEEN + PAXG (extended) | Reserve 10% + KGST/DEEN 50% + KGST/PAXG 40% | Mainnet example |

Any new pair must use Shariah-compliant assets — this is enforced by governance, not by code alone. PAXG is natively on Ethereum — bringing it to HAQQ L2 requires a dedicated bridge and formal agreement with Paxos for multi-chain support.

## Current Status

The protocol is deployed on HAQQ testedge2 (Chain 54211). The KGST/DEEN pool does not yet exist on Ethiq L2 mainnet — it will be created at mainnet launch. On testnet, the vault runs in reserve-only or simulated allocation mode.

Formal fatwa from the HAQQ Shariah Advisory Board is pending prior to mainnet launch.
