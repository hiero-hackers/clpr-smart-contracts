# EVM Platform Specification for CLPR

This document covers EVM-specific implementation choices that are valid bindings
of the platform-agnostic CLPR spec but are not normative across platforms. Each
section below records a binding decision that any EVM deployment of the CLPR
service makes; Hiero or other platform implementations may differ. Where the
platform-agnostic spec is silent, this document provides the normative EVM rule.

Cross-reference: DRIFT-REVIEW-2026-05.md Section 5 (E-1 through E-8).

---

## E-1 — Signature scheme and EIP-191 prefix

The EVM CLPR service uses **ECDSA over secp256k1** with an **EIP-191 personal
sign** prefix for both channel-reveal and connector-reveal signatures.

Before calling `ecrecover`, the service wraps the hash with:

```
"\x19Ethereum Signed Message:\n32"
```

### Channel-reveal

1. Compute `msgHash = keccak256(channelId ‖ address(this))`.
   The `address(this)` term domain-separates the signature to the specific
   router deployment, preventing replay on a different CLPR service that
   happens to derive the same `channelId` (DRIFT-REVIEW C?-10).
2. Apply EIP-191: `prefixedHash = keccak256("\x19Ethereum Signed Message:\n32" ‖ msgHash)`.
3. `ecrecover(prefixedHash, v, r, s)` must return the address derived from
   the supplied pubkey (see E-3).

### Connector-reveal

1. Compute `msgHash = keccak256(connectorId ‖ address(this))`.
2. Apply EIP-191: `prefixedHash = keccak256("\x19Ethereum Signed Message:\n32" ‖ msgHash)`.
3. `ecrecover` as above.

Implementation: `ConnectorLib._ecrecoverCheck` (shared by both code paths).

---

## E-2 — Connector balance model

The EVM service splits connector funds into two pools:

| Pool | Location | Purpose |
|---|---|---|
| **Operating balance** | Native ETH on the `connectorContract` itself | Pays for inbound message execution charges |
| **Slashable stake** | `Connector.lockedStake` in router storage | Misbehavior bond; subject to geometric slashing |

At charge time the service calls `IClprConnector.payForExecution(amount)` to pull
the execution cost from the connector contract. The router verifies the pull by
comparing its own ETH balance before and after; if the balance delta is not
exactly `amount`, the connector is slashed.

This model means:
- `topUpConnector` / `withdrawConnectorBalance` from spec §6.3 are **not** exposed
  by the EVM service. Operating balance management is the connector contract's
  own responsibility.
- Only `topUpConnectorStake` (for the slashable bond) is exposed.
- The spec's `Connector.balance` field does not exist in the EVM storage layout.

---

## E-3 — Public-key-to-address derivation

The EVM CLPR service requires **64-byte uncompressed secp256k1 public keys**
(X‖Y, no `0x04` prefix). The 33-byte compressed form is not supported in v1
because the EVM has no native decompression opcode.

Expected Ethereum address derived from a 64-byte pubkey `P`:

```
expectedAddress = address(uint160(uint256(keccak256(P))))
```

This is the standard Ethereum derivation (keccak of the uncompressed X‖Y bytes,
lower 20 bytes). Both channel-reveal and connector-reveal use this derivation.
The pubkey is stored in the commitment so cross-platform peers can verify it
without an out-of-band address lookup.

---

## E-4 — Admin authority: OZ Ownable

The platform-agnostic spec's "CLPR Service admin" role is bound to OZ
`Ownable` on the EVM. The owner address returned by `owner()` is the admin.

Operational deployments may wrap the owner slot with a multi-sig (e.g.,
Gnosis Safe) or a timelock (e.g., OZ TimelockController) without any change
to the CLPR contracts themselves. The service does not enforce any particular
ownership structure beyond "caller is `owner()`."

`setClprEnabled(bool)` is deliberately excluded from the kill-switch guard so
the owner can always re-enable the service.

---

## E-5 — Per-connector queue quota

Spec §8.11 ("Queue Monopolization") is marked as an open problem; the EVM
service provides a concrete resolution:

```
connectorQuota = connectorQueueQuotaPct * maxQueueDepth / 100
```

- `connectorQueueQuotaPct` and `maxQueueDepth` are fields in `EconomicConfig`
  and `Throttles` respectively, set by the service owner via
  `updateEconomicConfiguration` / `updateLedgerConfiguration`.
- Each connector's outstanding outbound DATA message count is tracked in
  `_connectorQueueCounts[channelId][keccak256(connectorId)]`.
- Sending a DATA message that would push the count above the quota reverts
  with `ClprQueueQuotaExceeded`.

This is an additive enforcement layer; connectors that stay within quota are
unaffected.

---

## E-6 — IClprConnector callback surface

The EVM CLPR service calls the registered connector contract to authorize
outbound messages, pay for inbound execution, and receive best-effort inbound
notifications:

```solidity
/// @notice Authorize an outbound message.
function authorizeOutboundMessage(
    bytes32 channelId,
    bytes calldata targetApplication,
    bytes calldata sender,
    bytes calldata messageData
) external returns (bool authorized);

/// @notice Pull payment for inbound message execution.
///         Called during submitBundle for each successfully dispatched DATA message.
///         The connector contract must transfer exactly `amount` wei to msg.sender
///         (the CLPR router). If the transfer underpays, the connector is slashed.
function payForExecution(uint256 amount) external;

/// @notice Best-effort inbound message notification.
///         Called after charge succeeds; failures are silently ignored.
///         Receives a bounded gas stipend (economicConfig.connectorInboundGasStipend).
function onInboundMessage(
    bytes32 channelId,
    uint64 messageId,
    bytes calldata sender,
    bytes calldata targetApplication,
    bytes calldata messageData
) external;
```

These methods are EVM-specific and are not expected to appear in the
platform-agnostic spec. Other platform implementations may use different
payment and notification primitives.

---

## E-7 — Geometric slashing (TODO: lift to platform-agnostic spec)

The EVM service implements geometric (exponentially escalating) slashing for
connector misbehavior:

```
penalty = basePenalty * penaltyMultiplier^slashCount
penalty = min(penalty, lockedStake)
```

Parameters are set per deployment in `EconomicConfig`:
- `basePenalty` — penalty for the first infraction.
- `penaltyMultiplier` — integer multiplier applied per slash (e.g., `2` for doubling).
- `slashBanThreshold` — if `slashCount >= slashBanThreshold` after a slash, the
  connector is permanently deleted (banned).
- Auto-ban also triggers if `lockedStake` reaches zero after a slash.

Slash proceeds go to the bundle submitter via `_transferWithFallback` (see E-8).

> **TODO: lift to spec.** Geometric slashing is a sound policy for all CLPR
> implementations (the escalation curve deters repeat offenders while a first
> infraction is recoverable). The Hiero implementation should adopt the same
> formula. Raise a clpr-spec issue to absorb E-7 into the platform-agnostic
> slashing section before the next spec revision.

---

## E-8 — Native-ETH transfer fallback chain

All outbound ETH transfers (slash proceeds to submitter, stake returns on
deregister, bond returns on endpoint removal) use `_transferWithFallback`:

1. **Attempt transfer to the primary recipient** — low-level `.call{value: amount}("")`.
2. **If that fails:** attempt transfer to `fallbackRecipient = owner()`.
3. **If that also fails:** credit `_pendingWithdrawals[recipient] += amount`.
   The recipient (or anyone on their behalf) may later call `collectPending()`
   to claim the accumulated balance.

This pattern ensures that a recipient contract that rejects ETH (e.g., a
contract with no `receive()`) never locks funds. The service never reverts on a
failed transfer; all funds are always recoverable.
