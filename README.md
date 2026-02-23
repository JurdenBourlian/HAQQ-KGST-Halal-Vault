# HAQQ-KGST Halal Vault

A Shariah-compliant yield protocol built natively on HAQQ Network. Users contribute KGST — the Kyrgyz Digital Som, the world's first state-issued fiat stablecoin — and receive `hvKGST`: an ERC-4626 share token that grows as the vault earns halal yield.

Every contribution is gated by an on-chain Shariah compliance oracle. Non-compliant transactions revert on-chain, unconditionally.

**Current status:** Testnet — deployed on HAQQ testedge2 (Chain 54211).  
**Next step:** Mainnet deployment on [Ethiq L2](https://l2-ethiq-landing.vercel.app) — the EVM-compatible L2 built by HAQQ Network.

> Requires [Foundry](https://getfoundry.sh/)

For a plain-language explanation of how the vault works and why it is halal, see [Overview](docs/OVERVIEW.md).

---

## Architecture

Five contracts wired through access-controlled interfaces:

```
User (HAQQ testedge2 / Ethiq L2 on mainnet)
      │
      ▼
┌─────────────────────────────┐
│    HalalVault (ERC-4626)    │
└──────────┬──────────────────┘
           │
     ┌─────┼──────────────────┐
     ▼     ▼                  ▼
┌──────────────┐  ┌────────────────────┐  ┌─────────────────┐
│ ShariahGuard │  │   StrategyRouter   │  │  FeeDistributor │
│  + Oracle(s) │  │  ├ V2Strategy      │  └─────────────────┘
└──────────────┘  │  └ ReserveStrategy │
                  └────────────────────┘

BNB Chain ──► Axelar GMP ──► AxelarBridgeReceiver ──► HalalVault
```

| Contract | Responsibility |
|----------|----------------|
| `HalalVault` | ERC-4626 vault. Deposit, withdraw, NAV, share accounting. |
| `ShariahGuard` | Pre-contribution compliance check via on-chain oracle(s). Reverts with `ShariahViolation` if non-compliant. Supports global and per-jurisdiction oracles. |
| `StrategyRouter` | Allocates capital across strategies (basis points). Pulls liquidity on withdrawal. |
| `UniswapV2Strategy` | AMM liquidity provision. TWAP-protected, IL tracking, harvest. Supports fee-on-transfer tokens. |
| `ReserveStrategy` | Liquid KGST buffer for instant withdrawals. |
| `AxelarBridgeReceiver` | Inbound cross-chain transfers from BNB Chain. Replay protection, rate limits, trusted-source whitelist. |
| `FeeDistributor` | Fee splitting. Founder share is immutable at deployment. |

---

## Testnet Addresses (HAQQ testedge2, Chain 54211)

All contracts verified on [HAQQ Explorer](https://explorer.testedge2.haqq.network) via Blockscout.

| Contract | Address |
|----------|---------|
| HalalVault | [`0x5c51760B1A4AbFF820A81f90D210167d2Aa69D68`](https://explorer.testedge2.haqq.network/address/0x5c51760B1A4AbFF820A81f90D210167d2Aa69D68) |
| ShariahGuard | [`0x330052857495FF6F1073825cf413fb4cd585d7ec`](https://explorer.testedge2.haqq.network/address/0x330052857495FF6F1073825cf413fb4cd585d7ec) |
| StrategyRouter | [`0x178908940AC057A1e5456413437d16E0555Ee68A`](https://explorer.testedge2.haqq.network/address/0x178908940AC057A1e5456413437d16E0555Ee68A) |
| ReserveStrategy | [`0xdDdC6BbD7289C38BF145360a0F4E5C9708b38c05`](https://explorer.testedge2.haqq.network/address/0xdDdC6BbD7289C38BF145360a0F4E5C9708b38c05) |
| FeeDistributor | [`0xF302C8f9929DC32239A544533b87892A93bAaF7A`](https://explorer.testedge2.haqq.network/address/0xF302C8f9929DC32239A544533b87892A93bAaF7A) |

> Mainnet addresses will be published after deployment to Ethiq L2.

---

## Installation

```bash
git clone https://github.com/JurdenBourlian/HAQQ-KGST-Halal-Vault.git
cd HAQQ-KGST-Halal-Vault
forge install
forge build
```

## Quick Start

```bash
forge test
```

```bash
cp .env.example .env
# Fill in RPC_URL, FOUNDER_ADDRESS, KGST_TOKEN_ADDRESS, multisig addresses

forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
forge script script/DeployDEX.s.sol --rpc-url $RPC_URL --broadcast
forge script script/SetupStrategies.s.sol --rpc-url $RPC_URL --broadcast
```

---

## Security

- Reentrancy guards on all state-modifying functions
- Role-based access control (OpenZeppelin `AccessControl`) — no single key holds all permissions
- `GUARDIAN_ROLE` can pause vault and bridge instantly and independently
- Single withdrawal capped at 10% of total vault assets per transaction
- Oracle staleness check — reverts if oracle data is older than `maxOracleAge`
- Bridge: trusted-source whitelist + nonce-based replay protection
- After deployment: `DEFAULT_ADMIN_ROLE` transferred to multisig, deployer key revoked

---

## Known Limitations

- `UniswapV3Strategy` is not yet implemented — the file exists as a structural placeholder. PAXG is natively on Ethereum; bringing it to HAQQ L2 requires a dedicated bridge and formal agreement with Paxos for multi-chain support.
- External security audit has not yet been scheduled.
- Formal fatwa from HAQQ Shariah Advisory Board is pending.

---

## Documentation

**Website:** [haqq-kgst.network](https://haqq-kgst.network)

- [Overview](docs/OVERVIEW.md) — how the vault works, plain language
- [Architecture](docs/ARCHITECTURE.md) — contracts, roles, security model, deployment checklist
- [API Reference](docs/API.md) — all functions, events, errors
- [Shariah Compliance](docs/SHARIAH.md) — Islamic finance principles, oracle architecture, fatwa status
- [Cross-Chain Bridge](docs/BRIDGE.md) — Axelar GMP flow, payload schema, rate limiting
- [Contributing](docs/CONTRIBUTING.md)
- [Code of Conduct](docs/CODE_OF_CONDUCT.md)

---

## Stack

Solidity `0.8.20` · OpenZeppelin · Foundry · ERC-4626 · Axelar GMP · HAQQ L2

## License

MIT
