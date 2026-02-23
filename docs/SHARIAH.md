# Shariah Compliance Framework

## Overview
The HAQQ-KGST-Halal-Vault is designed from first principles to comply with Islamic finance law (fiqh al-muamalat). Every architectural decision is driven by Shariah requirements, not merely adapted for them.

## Core Prohibitions Addressed

### Riba (Interest / Usury)
The protocol earns yield exclusively through trading fee income — a share of swap fees paid by market participants using the liquidity pools. This is categorically different from lending at interest. No loans are made, no fixed return is guaranteed, and the protocol takes market risk in exchange for fee revenue.

### Gharar (Excessive Uncertainty)
The protocol minimises gharar through:
- Use of only well-established assets (KGST, DEEN, PAXG)
- TWAP-based price validation before adding liquidity to AMM pools
- Transparent on-chain accounting — all positions are publicly verifiable
- Conservative slippage limits (max 5%) enforced by smart contract

### Maysir (Gambling)
All yield is derived from facilitating real economic activity (gold trading), not from zero-sum speculation. The protocol does not use derivatives, leverage, or prediction markets.

## Why Gold-Backed Tokens

Islamic finance has always recognised physical gold as the purest store of value. Tokens backed by physical gold represent a specific, identifiable, audited quantity of real gold. The primary pair on testnet is KGST/DEEN (1 DEEN = 1 gram, Brinks Dubai). The architecture supports additional gold-backed pairs such as KGST/PAXG (1 PAXG = 1 troy oz, Paxos vaults, London) on mainnet.

When the vault provides liquidity to these pools, it facilitates the exchange of two real assets: a state-issued currency and physical gold. The trading fees earned are service revenue for enabling this exchange — analogous to a gold merchant charging a commission.

| Token | Backing | Shariah Status |
|-------|---------|----------------|
| KGST | Kyrgyz Som (state currency) | Permissible — fiat currency |
| DEEN | 1 gram physical gold, Brinks Dubai | Certified — HAQQ Shariah Board fatwa |
| PAXG¹ | 1 troy oz physical gold, Paxos London | Permissible — gold ownership |

> ¹ PAXG is natively on Ethereum. Availability on HAQQ L2 requires a dedicated bridge and formal agreement with Paxos for multi-chain token support.

## Permitted and Prohibited Activities

| Activity | Permitted | Basis |
|----------|-----------|-------|
| DEX liquidity provision (V2) | ✅ | Trading fee income = service revenue |
| Holding idle assets in reserve | ✅ | Capital preservation |
| Interest-bearing lending | ❌ | Riba |
| Leveraged derivatives | ❌ | Gharar / Maysir |
| Yield farming with anonymous protocols | ❌ | Gharar |

## Oracle Architecture

```
ShariahGuard
├── globalOracle              ← HAQQ Shariah Advisory Board (mandatory for all users)
└── jurisdictionalOracles     ← per-country boards (optional, additive)
    ├── KG — keccak256("KG")
    ├── AE — keccak256("AE")
    └── ...
```

Both global and jurisdictional oracles must return `true` for a transaction to proceed. Regional oracles add constraints — they cannot override or relax the global oracle.

Oracle freshness is enforced: transactions revert if oracle data is older than `maxOracleAge` (configurable, default 24h).

## Fatwa Status

The vault's architecture and on-chain mechanics are subject to formal fatwa review prior to mainnet launch. Draft documentation has been prepared for submission to the HAQQ Shariah Advisory Board.

**Until fatwas are formally issued and published, the vault should not be treated as a certified Shariah-compliant product.** The architecture is designed for compliance but requires formal scholarly review.
