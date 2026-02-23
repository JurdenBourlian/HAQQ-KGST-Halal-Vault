# Cross-Chain Bridge (Axelar)

## Overview
Users on BNB Chain can transfer KGST into the HAQQ L2 vault using the Axelar General Message Passing (GMP) protocol. The bridge is one-way for inbound flows; withdrawals return KGST natively on HAQQ L2.

## Architecture
```
BNB Chain                    Axelar Network               HAQQ L2
─────────────────────────    ────────────────────────     ──────────────────────────────
User
│
├── 1. Approve KGST transfer
│
├── 2. Call BridgeSender.sendDeposit(amount, autoDeposit, nonce)
│       │
│       ├── Lock KGST in BNB escrow contract
│       └── Submit GMP payload to Axelar gateway
│
──────────────────────►
      Axelar relayers validate
      and relay proof
│
├── 3. AxelarBridgeReceiver.execute()
│       called by Axelar gateway
│
├── 4. Validate trusted source
│       (source chain + sender)
│
├── 5. Replay protection (nonce check)
│
├── 6. Enforce rate limits
│
├── 7a. If autoDeposit = true:
│         mint KGST → vault.deposit()
│
└── 7b. If autoDeposit = false:
         release KGST to recipient
```

## GMP Payload Schema
The payload is ABI-encoded with the following fields:
```solidity
(address recipient, uint256 amount, bool autoDeposit, uint64 nonce)
```

| Field | Type | Description |
|-------|------|-------------|
| recipient | address | HAQQ L2 address to receive KGST or hvKGST |
| amount | uint256 | Amount in KGST (18 decimals) |
| autoDeposit | bool | If true, recipient receives hvKGST shares; if false, raw KGST |
| nonce | uint64 | Per-sender nonce to prevent replay attacks |

The nonce is incremented per `(sourceChain, sender)` pair on the sending side, ensuring that two identical transfers produce different message hashes.

## Security Controls

### Trusted Sources
Only whitelisted `(sourceChain, sourceAddress)` pairs are accepted. Any other source is rejected before any state change.
```solidity
mapping(string => string) public trustedSources;
```

### Replay Protection
Each message is uniquely identified by a hash that includes the nonce:
```solidity
bytes32 messageHash = keccak256(abi.encodePacked(
    sourceChain,
    sourceAddress,
    recipient,
    amount,
    autoDeposit,
    nonce,
    block.chainid
));
```
Once processed, the hash is marked to prevent duplicate execution.

### Rate Limiting
Two-tier rate limiting prevents large sudden inflows:
- **Global per-block limit:** Total inflow across all users
- **Per-user per-block limit:** Individual user cap

If a limit would be exceeded, the transaction reverts with `RateLimitExceeded` or `UserRateLimitExceeded`.

### Emergency Pause
The `GUARDIAN_ROLE` can pause the bridge receiver independently of the vault.

## Supported Chains
| Chain | Status | Source Contract |
|-------|--------|-----------------|
| BNB Chain mainnet | Planned | TBD |
| BNB Chain testnet | In development | TBD |

Additional chains can be added by the bridge admin by registering new trusted sources.

## Fees
- **Axelar relay fee:** Paid by the user on BNB Chain (variable, depends on gas price)
- **Protocol bridge fee:** Currently 0. Subject to governance change
- **Vault entry fee:** Subject to vault fee configuration (see FeeDistributor)