# Architecture

Read this when changing storage, public API, or moving code between contracts.
Pairs with `CLPR.md`.

## DELEGATECALL router pattern

`ClprService` is the only contract anyone interacts with. It declares the
storage and the public ABI but contains no business logic. Each external
function is a tiny stub that DELEGATECALLs into one of four logic contracts:

```
                   ClprService  (router; state lives here)
                        │
       ┌────────────────┼────────────────┬────────────────┐
       │ DELEGATECALL   │                │                │
       ▼                ▼                ▼                ▼
  ChannelLogic  MessagingLogic  ConnectorLogic    AdminLogic
```

- Logic contract addresses are `immutable`, set in the router constructor.
- The system is **not upgradeable**.
- The split exists to fit under the EIP-170 24KB code size limit and to
  organise concerns; it is not a proxy/upgrade pattern.
- `deriveConnectorId` is the one function dispatched via STATICCALL
  (`_staticDelegate`) because it is `pure`.

The router and every logic contract inherit `ClprServiceStorage` in the same
position so storage slots line up under DELEGATECALL.

### Service Authorization (onlyService modifier)

All state-changing methods in logic contracts are protected by the `onlyService`
modifier. This checks `address(this) == _authorizedService` to ensure the method
is called via DELEGATECALL from ClprService, not directly on the logic module.

- **Direct call**: `address(this)` = logic module's address ≠ `_authorizedService` → reverts
- **DELEGATECALL**: `address(this)` = ClprService's address == `_authorizedService` → succeeds

The `_authorizedService` field is shared across all contracts via `ClprServiceStorage`
inheritance and is set once during ClprService initialization.

### Why functions aren't `view`

Solidity 0.8 forbids `delegatecall` inside `view`. So almost every read
function on `IClprService` is non-view at the ABI level. Off-chain callers
use `eth_call` (a STATICCALL) and pay no gas; on-chain callers must accept the
non-view signature. `IClprService` documents this; don't "fix" it.

### Logic contract constructors

Logic contracts are stateless code fragments executed only via DELEGATECALL.
Their constructors are empty (no initialization needed). `ClprServiceStorage`
inherits from `OwnerAccessible`, which defines a virtual `_getOwner()` function.
Only `ClprService` overrides this to return `owner()` (via `Ownable`); logic
contracts inherit the base implementation. Ownership is centralized in ClprService.

## Public ABI dispatch table

| `IClprService` function | Logic contract | Authorization | Notes |
|---|---|---|---|
| `registerChannel(channelId, commitment)`, `completeChannel`, `deriveChannelId`, `getChannel`, `pendingCommitments`, `channelCount` | `ChannelLogic` | User-initiated | — |
| `closeChannel` | `ChannelLogic` | Owner-only (`onlyOwner` + `onlyService`) | Visits pending commitments via reverse index as well as active channels |
| `sendMessage` | `MessagingLogic` | User-initiated (`onlyService`) | — |
| `submitBundle` | `MessagingLogic` | Endpoint-gated (`onlyService`) | Caller must be registered endpoint |
| `redactMessage` | `MessagingLogic` | Owner-only (`onlyOwner` + `onlyService`) | — |
| `getMessage` | `MessagingLogic` | None (view) | — |
| `registerConnector`, `completeConnector` (payable), `removeConnector`, `topUpConnectorStake` (payable) | `ConnectorLogic` | User-initiated (`onlyService`) | — |
| `getConnector`, `hasConnector`, `deriveConnectorId` (STATICCALL), `pendingConnectorCommitments`, `connectorCount` | `ConnectorLogic` | None (view) | — |
| `setClprEnabled(bool)` | `AdminLogic` | Owner-only (`onlyOwner` + `onlyService`) | Never gated by kill switch so owner can always re-enable; `enabled = true` reverts (`ClprNotInitialized`) unless `initialize()` has already run |
| `initialize(...)` | `AdminLogic` | Owner-only (`onlyOwner` + `onlyService`) | One-time bootstrap: applies ledger + economic config atomically while still disabled. Not gated by the kill switch. Reverts (`ClprAlreadyInitialized`) if called more than once |
| `updateLedgerConfiguration`, `updateEconomicConfiguration` | `AdminLogic` | Owner-only (`onlyOwner` + `onlyService`) | Gated by kill switch — for reconfiguring an already-running service, not initial bootstrap (see `initialize`) |
| `registerEndpoint` (payable), `removeEndpoint`, `topUpBond` (payable) | `AdminLogic` | User-initiated (`onlyService`) | — |
| `isRegistered`, `getEndpoint`, `getLedgerConfiguration`, `getEconomicConfig`, `pendingWithdrawals`, `collectPending`, `endpointCount` | `AdminLogic` | None (view) | `collectPending` is pull-payment, non-reentrant |
| `receive() payable {}` | router | None | Only on-router-direct logic |

## Outward-bound interfaces (the protocol calls these)

| Interface | Methods | Called from |
|---|---|---|
| `IClprVerifier` | `verifyConfig` (during completeChannel), `verifyBundle` (during submitBundle) | `ChannelLogic._createChannel`, `BundleLib.processBundle` |
| `IClprApplication` | `onClprMessage` (gas-bounded, return value becomes REPLY payload), `onClprResponse` (best-effort) | `BundleLib._processDataMessage`, `BundleLib._processReplyMessage` |
| `IClprConnector` | `authorizeOutboundMessage` (during sendMessage), `payForExecution` (pull-payment during inbound DATA), `onInboundMessage` (best-effort) | `MessagingLogic._authorizeConnector`, `ConnectorLib.charge`, `BundleLib._processDataMessage` |

## Storage (`ClprServiceStorage.sol`)

**Hard rule:** order, names, and types here are part of the deployment ABI in
the storage sense. Reordering breaks every existing deployment. New fields
must be appended at the end. See `quirks.md` for why the OZ ReentrancyGuard
namespaced slot does not interfere.

| Field | Type | Purpose |
|---|---|---|
| `_authorizedService` | address | Shared authorization field: set to ClprService address; checked by all logic module state-changing methods via `onlyService` modifier to prevent direct calls |
| `_owner` (Ownable) | address | router owner; admin authority |
| `_config` | `LedgerConfiguration` | protocolVersion, local chainId, serviceAddress, timestamp, throttles, seedEndpoints[] |
| `economicConfig` | `EconomicConfig` | execution costs, margins, stake/bond minima, penalty params, gas stipend, max counts |
| `_channels` | `mapping(bytes32 ⇒ Channel)` | keyed by channelId |
| `_channelExists` | `mapping(bytes32 ⇒ bool)` | existence flag |
| `_pendingCommitments` | `mapping(bytes32 ⇒ bool)` | commit-phase set; key = `keccak256(channelId‖pubKey)` |
| `_messageQueues` | `mapping(bytes32 ⇒ mapping(uint64 ⇒ MessageValue))` | per-channel queue keyed by messageId |
| `_connectors` | `mapping(bytes32 ⇒ Connector)` | key = `keccak256(channelId‖connectorId)` (channel-scoped!) |
| `_connectorExists` | `mapping(bytes32 ⇒ bool)` | |
| `_pendingConnectorCommitments` | `mapping(bytes32 ⇒ bool)` | key = `keccak256(connectorId‖pubKey)` |
| `_connectorInflightCount` | `mapping(bytes32 ⇒ uint256)` | inner key = `keccak256(channelId‖connectorId)`; gates `removeConnector` |
| `_connectorQueueCounts` | `mapping(bytes32 ⇒ mapping(bytes32 ⇒ uint32))` | `[channelId][keccak256(connectorId)]`; per-connector quota |
| `_endpoints`, `_endpointExists` | `mapping(address ⇒ …)` | bonded endpoint operators |
| `_endpointCount`, `_channelCount`, `_connectorCount` | `uint256` | counters for caps and views |
| `_pendingWithdrawals` | `mapping(address ⇒ uint256)` | pull-payment fallback when push transfer fails |
| `_bundleDecodeHelper` | `address` | immutable helper contract for `try/catch` around protobuf decode in BundleLib |
| `_clprEnabled` | `bool` | global kill switch; initialized `false`; toggled by `setClprEnabled(bool)` (owner-only); enabling reverts unless `_isInitialized` is already `true` |
| `_isInitialized` | `bool` | one-time bootstrap flag; initialized `false`; set `true` by `initialize(...)` (owner-only, once) |
| `_channelIdToCommitment` | `mapping(bytes32 ⇒ bytes32)` | reverse index: `channelId → commitment`; populated at `registerChannel`; deleted at `completeChannel` or `closeChannel`; enables `closeChannel` to purge pending commitments |

> ⚠ Two distinct hashes for connector lookup coexist. The `Connector` record
> key is `keccak256(channelId‖connectorId)`. The inner key for
> `_connectorQueueCounts` is `keccak256(connectorId)` *only* (the outer
> mapping already keys by channelId). Mixing them up silently corrupts
> accounting.

## Key data structures (in `ClprTypes.sol`)

- **`Channel`** — slot-packed: `channelId`(s0), `verifier+status+nextMessageId`(s1), two `uint64` counters (`ackedMessageId`, `receivedMessageId`) and two `uint96` nanos timestamps (`peerConfigTimestamp`, `lastConfigTimestamp`)(s2), three `bytes32` (`sentRunningHash`, `receivedRunningHash`, `ownershipCommitment`)(s3-5), `salt`, then dynamic `chainId` (peer chain), `peerServiceAddress`, `peerThrottles` (populated at `completeChannel` from `IClprVerifier.verifyConfig`; also updated when an inbound CONTROL message carries a new peer config — see `BundleLib._processControlMessage`), `trustAnchor` (populated from verifier at `completeChannel`; updated on trust-anchor rotation by `verifyBundle`). Lifecycle and status semantics are normative — see spec §2.1.1. **Public-key encoding:** 64-byte uncompressed secp256k1 (X‖Y, no 0x04 prefix) — see `quirks.md` "EVM pubkey encoding" for why 33-byte compressed is not supported on EVM in v1.
- **`Connector`** — `connectorId`, `connectorContract`, `admin`, `lockedStake`, `slashCount`. Operating funds for execution charges live as native balance on `connectorContract`; `lockedStake` is the slashable bond held in the router.
- **`MessageValue`** — protobuf payload + `runningHashAfterProcessing`. Redaction zeros the payload while keeping the slot (so subsequent running-hash continuity holds).
- **`Endpoint` vs `RegisteredEndpoint`** — the former is the off-chain seed-list entry embedded in `LedgerConfiguration`; the latter is the on-chain bonded operator (with bond and slashCount).
- **`QueueMetadata`** — return shape from `IClprVerifier.verifyBundle`. Enum value order is wire-compatible with the on-chain encoder; the canonical proto enum for `ChannelStatus` is not yet pinned in the spec (see clpr-spec issue tracking S-1) — the EVM service uses the ordering defined in `ClprTypes.ChannelStatus`.

## Library responsibilities

| Library | Responsibility | Takes storage refs? |
|---|---|---|
| `BundleLib` | Bundle processing pipeline (spec §4.2 + §4.5) | yes — heavy |
| `ConnectorLib` | Connector commit-reveal, charge, slash, pull-payment fallback | yes |
| `EndpointLib` | Endpoint bond accounting | yes |
| `ClprProtobuf` + `…Helpers` | Hand-rolled proto codec for DATA / REPLY / CONTROL / BundleContent | no (pure) |
| `ClprTypes` | Enums, structs, custom errors, and *file-scope events* `ChannelStatusChanged` and `MessageQueued` (declared at file scope so router and libs share one ABI selector) | no |

## Native-token (ETH) flows

- **In:** `registerEndpoint` / `topUpBond` (endpoint bond), `completeConnector` / `topUpConnectorStake` (connector stake), and `payForExecution` (pull-payment from connector contract during inbound DATA).
- **Out:** slash / charge proceeds → bundle submitter (or `_fallbackRecipient = owner`, then `_pendingWithdrawals` if both reject); `removeConnector` returns remaining stake; `removeEndpoint` returns remaining bond.
- **Charge verification** is by router-balance delta in `ConnectorLib.charge`: after `payForExecution(amount)` the router must have gained exactly `amount`. If not, the connector is slashed.
- **`_pendingWithdrawals`** is the safety net: if a push transfer reverts (recipient is a contract that rejects), the amount is credited to a pull queue claimable via `collectPending()`.
