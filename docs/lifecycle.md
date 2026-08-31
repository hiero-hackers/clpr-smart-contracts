# Channel & Connector Lifecycle (EVM specifics)

Read this when changing commit-reveal flows, ID derivation, or signature
verification. Pairs with spec §5.1 (channel registration) and §6.3
(connector registration).

> **Resolved divergences:**
> - C?-10 (channel-reveal sig domain separation): fixed — sig now over
>   `keccak256(channelId ‖ address(this))` to bind to the specific router.
> - S-7/D-6 (pubkey encoding): EVM requires 64-byte uncompressed secp256k1
>   (X‖Y, no 0x04 prefix). The spec also permits 33-byte compressed; EVM does
>   not implement compressed-key support in v1 (no native decompression opcode).
>   Per Richard's decision (DRIFT-REVIEW S-7), this is ledger-specific. See
>   `quirks.md` "EVM pubkey encoding is 64-byte uncompressed."
> - I-2/I-1 (PENDING channels never closeable): fixed — `closeChannel`
>   now visits both active channels and pending commitments. `registerChannel`
>   takes an additional `channelId` parameter to build a reverse index.
> - I-5 (kill switch): implemented — `setClprEnabled(bool)` gates all mutating ops.
> - S-4 (channel ID derivation): the spec §2.1 previously said channel ID
>   is "registrant-chosen"; the canonical form is the derived formula below
>   (`keccak256(loChain ‖ hiChain ‖ pubKey ‖ salt)` with chains sorted by
>   `keccak256`). The spec will be updated; clpr-relay and clpr-hiero also need
>   updating for cross-platform byte equivalence.

The spec defines *what* is signed and *how* IDs derive. This doc records the
EVM-specific encodings: byte-for-byte hash inputs, `ecrecover` quirks, the
significance of `address(this)` under DELEGATECALL, etc.

## PENDING state

A channel enters **PENDING** between `registerChannel` (commitment
recorded) and `completeChannel` (signature reveal and verifier wired up).
PENDING records are stored exclusively in `_pendingCommitments` and
`_channelIdToCommitment`; there is **no** `Channel` entry in
`_channels` until `completeChannel` succeeds. This means any code path
that looks up `_channels[channelId]` will find an empty struct for a
PENDING channel — do not treat a missing `_channels` entry as an error
without first checking for a pending commitment.

During PENDING, only two storage entries exist:

- `_pendingCommitments[commitment] = true` — proves the commitment was seen.
- `_channelIdToCommitment[channelId] = commitment` — reverse index that
  lets `closeChannel` find and purge the pending entry.

No `Channel` record is stored; the channel is not in `_channels`.
Incoming bundles for a PENDING channel are rejected defensively (`BundleLib`
checks for `status == PENDING` per DRIFT-REVIEW C?-9 fix).

An admin may abort a PENDING channel by calling `closeChannel(channelId)`.
This deletes both the pending commitment and the reverse-index entry (per the
I-1/I-2 fix in Wave 4). There is no on-chain timeout; commitments are otherwise
permanent unless completed or explicitly closed.

## Channel: commit-reveal

### Phase 1 — `registerChannel(channelId, commitment)`

- `commitment = keccak256(channelId ‖ pubKey)` where `pubKey` is the
  64-byte uncompressed secp256k1 public key (X‖Y, **no 0x04 prefix**).
- `channelId` is the value from `deriveChannelId(peerChainId, pubKey, salt)`.
  It is passed explicitly so the service can build a reverse index
  (`channelId → commitment`) enabling `closeChannel` to purge pending
  entries (spec §5.1.4). The service does NOT validate `channelId` at this
  phase — validation happens at `completeChannel`.
- Sets `_pendingCommitments[commitment] = true` and
  `_channelIdToCommitment[channelId] = commitment`. Idempotent and
  permissionless (re-registering the same commitment is a no-op).

### Phase 2 — `completeChannel(channelId, pubKey, sig, salt, verifier, configProof, endpointManifestProof)`

In `ChannelLogic.completeChannel` (`ChannelLogic.sol:35-50`):

1. Recompute `keccak256(channelId‖pubKey)` and assert it was registered.
2. Assert channel isn't already created.
3. Verify `sig` (65 bytes, `r‖s‖v`):
   - `pubKey.length == 64` (EVM v1 requires 64-byte uncompressed; see `quirks.md`)
   - `msgHash = keccak256(channelId ‖ address(this))` — domain-separated to
     the specific router deployment so signatures cannot be replayed on a
     different CLPR service that derives the same `channelId`.
   - In `ConnectorLib._ecrecoverCheck`: prepend `"\x19Ethereum Signed Message:\n32"`,
     hash, `ecrecover`, and assert recovered address equals
     `address(uint160(uint256(keccak256(pubKey))))`. The "expected address"
     is derived directly from the pubkey bytes — not from a separate signing
     address — so the protocol can carry the full pubkey in the commitment
     (needed for cross-platform parity).
4. Assert `verifier.code.length > 0`.
5. `IClprVerifier.verifyConfig(configProof, channelId, endpointManifestProof)` →
   `(channelContext, peerChainId, peerServiceAddress, peerConfigNanos, peerThrottles,
   initialTrustAnchor, initialTrustAnchorId, endpointManifest)`.
   The trust anchor, peer throttles, and initial peer endpoint manifest are sourced
   from the verifier — callers do not supply them directly. The manifest is stored
   out-of-line (`_peerEndpointManifests[channelId]`), truncated to the local
   `maxPeerEndpoints` throttle. An empty `endpointManifestProof` is a bring-up path:
   the Channel starts with `endpointManifestVersion = 0` (uninitialized) and the
   first manifest-carrying bundle populates it via BundleLib Step 1b.
6. Re-derive `channelId` and assert it matches the one supplied
   (`ClprInvalidChannelId`).
7. Populate `Channel`: `status = ACTIVE`, `nextMessageId = 1`,
   `lastConfigTimestamp = block.timestamp`, store `salt`, `ownershipCommitment`,
   `peerThrottles`, `trustAnchor` (from verifier).
8. Increment `_channelCount`; delete the pending commitment from
   `_pendingCommitments` and the reverse-index entry from
   `_channelIdToCommitment`; emit `ChannelCompleted` (with
   `keccak256(verifier.code)` as a fingerprint) and
   `ChannelStatusChanged(ACTIVE)`.

### `deriveChannelId(peerChainId, pubKey, salt)`

Sorts the local and peer chainIds by `keccak256` so both peers compute
**byte-identical** ids:

```
(loChain, hiChain) = sortByKeccak(localChainId, peerChainId)
channelId       = keccak256(loChain ‖ hiChain ‖ pubKey ‖ salt)
```

The local chainId comes from `_config.chainId` (set in the router constructor).

### Verifier immutability

After `completeChannel`, the channel's verifier address cannot be
changed (spec §5.1.5). There is no setter; enforced by absence.

## Connector: commit-reveal

### Phase 1 — `registerConnector(commitment)`

- `commitment = keccak256(connectorId ‖ pubKey)`.
- `connectorId = keccak256(channelId ‖ pubKey ‖ salt)`. Computed via
  `deriveConnectorId` (the only `pure` STATICCALL in the router).
- Sets `_pendingConnectorCommitments[commitment] = true`.

### Phase 2 — `completeConnector(connectorId, pubKey, sig, salt, channelId, connectorContract, admin) payable`

In `ConnectorLib.completeRegistration`:

1. Verify commitment from `(connectorId, pubKey)`.
2. Re-derive `connectorId` from `(channelId, pubKey, salt)`; assert match.
3. Signed message is `keccak256(connectorId ‖ address(this))`. Note:
   - Under DELEGATECALL, `address(this)` is the **router** address, so the
     signature binds to a specific router deployment.
   - This is the EVM equivalent of the spec's "service_address" binding
     (spec §6.3 callout).
4. `ecrecover` against `keccak256(pubKey)`-derived address (same scheme as
   channel completion).
5. Assert `connectorContract.code.length > 0` and `msg.value ≥ minLockedStake`.
6. Populate `Connector`, increment `_connectorCount`, delete pending commitment.

### `deregister` (`removeConnector`)

- Caller must be the connector's `admin`.
- `_connectorInflightCount[key] == 0` required (no in-flight DATA messages).
- Returns the `lockedStake` to `recipient` via `_transferWithFallback`.
- Deletes the entry; the connector can be re-registered later under a new
  commitment.

### Slashing

`ConnectorLib.slash` is invoked from `BundleLib`:
- penalty = `basePenalty * penaltyMultiplier^slashCount`, capped at `lockedStake`
- if `slashCount >= slashBanThreshold` OR `lockedStake → 0`, the entry is deleted
- proceeds go to bundle submitter via `_transferWithFallback`

## Endpoint registration (single phase)

`registerEndpoint(signingKey) payable` (in `AdminLogic`):
- `signingKey.length == 64` (else `ClprInvalidSignature` — selector reused for
  structural validation; tests pin this in `test/logic/AdminLogic.t.sol:148`)
- `msg.value ≥ minEndpointBond`
- creates a `RegisteredEndpoint` for `msg.sender`

`removeEndpoint` returns the bond, `topUpBond()` adds to it. Endpoints are
the only callers allowed into `submitBundle`.

## Cross-platform byte-equivalence checklist

When changing any of the following, audit against the peer-ledger
implementation (Hiero, etc.) for matching bytes:

| Quantity | Formula |
|---|---|
| `channelId` | `keccak256(loChain ‖ hiChain ‖ pubKey ‖ salt)`, chainIds sorted by `keccak256` |
| `connectorId` | `keccak256(channelId ‖ pubKey ‖ salt)` |
| Channel commitment | `keccak256(channelId ‖ pubKey)` |
| Connector commitment | `keccak256(connectorId ‖ pubKey)` |
| Channel-reveal sig over | `"\x19Ethereum Signed Message:\n32" ‖ keccak256(channelId ‖ address(this))` (domain-separated to router address) |
| Connector-reveal sig over | `"\x19Ethereum Signed Message:\n32" ‖ keccak256(connectorId ‖ address(this))` |
| Bundle running hash | `sha256(prev ‖ sha256(payload))`, prev seeded with 32 zero bytes |
| Endpoint bundle sig (verifier-side) | `keccak256(channelId ‖ bundle_payload)` (spec §1.5) |

`pubKey` everywhere means the **64-byte uncompressed** secp256k1 representation
(X‖Y), no 0x04 prefix. The spec also allows 33-byte compressed, but EVM v1
does not support it — see `quirks.md` "EVM pubkey encoding is 64-byte
uncompressed." Hash function defaults: `keccak256` for IDs and commitments;
`sha256` only for the bundle running hash.
