# Bundle Processing Flow

Read this when touching `BundleLib`, `MessagingLogic.submitBundle`, or any
inbound message handling. Pairs with spec §4.2 (bundle verification),
§4.3 (enqueue), §4.5 (response ordering), §4.6 (slashing decisions).

> ⚠ **Known divergences vs spec** — read `DRIFT-REVIEW-2026-05.md`. Notably:
> outbound payload size is checked against local throttles instead of peer
> throttles (C-2); `Channel.peerThrottles` is never populated (C-3);
> `redactMessage` leaks the in-flight counter (C-4); cross-bundle response
> ordering is not validated (C?-7); CLOSING + bad-ordering doesn't reject
> (C?-8); per-message decode reverts unwind the whole bundle (C?-11). The
> step-numbering below is the code's, not spec §4.2's.

> **Sender stamping (C-1 fixed):** `sendMessage` stamps `msg.sender` as the
> sender in outbound DATA messages. The public ABI does not accept a caller-
> supplied `sender` argument. This implements spec §4.3 step 6 and prevents
> sender spoofing. Destination-side applications may rely on the `sender`
> field to identify the on-chain source caller, but must not trust any
> in-band "from" claim inside `messageData`. See `quirks.md` for details.

## Entry

`ClprService.submitBundle(channelId, proofBytes)` → DELEGATECALL →
`MessagingLogic.submitBundle` (`MessagingLogic.sol:50`):

1. Caller must be a registered endpoint (`isRegistered[msg.sender]`).
2. Channel must exist.
3. Forwards a pile of storage refs into `BundleLib.processBundle`.

The router holds all state; `BundleLib` mutates it via passed-in references.

## Step numbering cross-reference

The code breaks the spec's 6 high-level steps into 12 implementation steps for
clarity. The table below maps each spec step (§4.2) to the corresponding code
step(s). Keep this in sync when adding or reordering steps.

| Spec §4.2 step | Code step(s) | Summary |
|---|---|---|
| 1 — Validate bundle | 1, 2, 3 | Channel lookup, size check, verifier call |
| 2 — Replay defence | 4 | nextMessageId continuity |
| 3 — Running-hash check | 5 | SHA-256 chain comparison |
| 4 — Ack monotonicity | 6 | Ack bounds check |
| 5 — Response ordering (§4.5) | 7 | `_checkResponseOrdering` pre-pass |
| 5a — Auto-resume | 8 | PAUSED → ACTIVE on clean bundle |
| 5b — Peer-close propagation | 9 | ACTIVE → CLOSING on peer CLOSING/DRAINED |
| 5c — Queue maintenance | 10a, 10b | Delete acked non-DATA; lazy config enqueue |
| 6 — Dispatch messages | 10c | Per-message dispatch (DATA/REPLY/CONTROL) |
| (state-machine) | 11 | ACTIVE→CLOSING→DRAINED→CLOSED transitions |
| (persist) | 12 | Write Channel back; emit `BundleProcessed` |

## Pipeline (steps map to spec §4.2)

`BundleLib.processBundle` does steps 1–6, then `_finishBundle` does 7–12.

| Step | What | Code |
|---|---|---|
| 1 | Channel lookup; revert if peer is `CLOSED` | `BundleLib.sol:60-65` |
| 2 | `proofBytes.length ≤ throttles.maxSyncBytes` | `:67-70` |
| 3 | `IClprVerifier.verifyBundle(proofBytes, channel.trustAnchor)` → `(metadata, payloads[], newAnchor)`. Cap message count and per-payload size. Adopt `newAnchor` if non-empty. Reject empty bundles that change nothing. | `:72-97` |
| 4 | Replay defense: `metadata.nextMessageId − (channel.receivedMessageId+1) == payloads.length` | `:107-114` |
| 5 | Running-hash check: seed with `channel.receivedRunningHash` (or 0 first time), fold `sha256(prev‖sha256(payload))` over each, compare to `metadata.sentRunningHash`. Uses the EVM `sha256` precompile. | `:300-311` |
| 6 | Ack monotonicity: new ack ≥ old ack and (if changed) `< own nextMessageId` | `:129-136` |
| 7 | Response-ordering pre-pass (`_checkResponseOrdering`): single decode pass extracting `MessageType` + `replyId` per payload; ensure each acked outbound DATA has a matching inbound REPLY in order, and trailing REPLYs don't reference unacked ids. **Violation pauses the channel (ACTIVE→PAUSED) and aborts.** See spec §4.5. | `:253-308` |
| 8 | Auto-resume: PAUSED → ACTIVE on a clean bundle | `_finishBundle :169-172` |
| 9 | Peer close propagation: peer `CLOSING/DRAINED` + own `ACTIVE` → `CLOSING` | `:175-182` |
| 10a | Delete acked CONTROL/REPLY messages from queue (DATA messages stay until their REPLY arrives, since redaction would lose the connectorId needed for accounting) | `_deleteAckedNonDataMessages :312-327` |
| 10b | Lazy config-update enqueue: if `_config.timestamp` advanced and channel is ACTIVE, enqueue a CONTROL message via `_enqueueConfigUpdate` (spec §4.3 step 1a) | `:188-190` |
| 10c | Per-message dispatch | `_dispatchMessages :349-374` |
| 11 | State-machine transitions: ACTIVE→CLOSING→DRAINED→CLOSED based on metadata + own queue | `_applyStateMachine :215-249` |
| 12 | Persist updated `Channel`; emit `BundleProcessed` | `:208` |

## Per-message dispatch (`_dispatchMessages`)

Strict wire-format policy first: after version negotiation, both services share the exact same
wire vocabulary, so malformed input is triaged by what it proves about the sender:

- **Unknown `ClprMessage` discriminator** (oneof tag outside 1-4) → the ENTIRE bundle reverts
  with `ClprUnknownWireField`. The sender runs the wrong protocol version or emits malformed
  output; its data cannot be trusted.
- **Unknown field inside any protocol message** (DATA body, REPLY body, CONTROL configuration,
  throttles, endpoints, …) → same: `ClprUnknownWireField`, whole bundle rejected. The decoders in
  `ClprProtobuf` revert instead of skipping, and the DATA/CONTROL dispatch catches re-throw this
  specific error rather than degrading it to a per-message reply.
- **Missing/garbled field in a DATA message** → per-message recovery: `BundleParseFailed` +
  `APPLICATION_ERROR` reply; the rest of the bundle processes and the source application can
  react (e.g. redact the malformed message).
- **Malformed REPLY message** → the ENTIRE bundle reverts. A reply that cannot be decoded can
  never be matched against the outbound queue, so response ordering could never advance past it;
  there is no in-protocol recovery. The channel stays blocked until the remote CLPR Service is
  fixed (permanently, if that contract is immutable).
- **Enum value out of range** (`ReplyStatus`, `ChannelStatus`, protocol enums) → bundle
  rejected with a descriptive error, never an implicit enum-conversion panic and never a silent
  default.

Rejection is atomic: messages dispatched before the offending one are unwound with the rest of
the transaction, so a corrected re-encoding of the same bundle applies cleanly later.

Three cases, switching on `MessageType`:

### CONTROL (`_processControlMessage`)
Updates `peerConfigTimestamp` and `peerThrottles` in the in-memory `Channel`.

### DATA (`_processDataMessage`, `:386-465`)

```
if channel is closing/closed:                 reply CHANNEL_CLOSED
else if connector lookup fails:                  reply CONNECTOR_NOT_FOUND
else if connectorContract.balance <
   messageExecutionCost*(1 + margin/100):        slash + reply CONNECTOR_UNDERFUNDED
else:
   try IClprApplication.onClprMessage{gas: maxGasPerMessage}
       on revert:                                reply APPLICATION_ERROR
       on success:
           ConnectorLib.charge(amount)           # calls payForExecution; verifies
                                                 # router balance grew by exactly amount
           if charge fails:                      slash + reply CONNECTOR_UNDERFUNDED
           else:
               best-effort onInboundMessage      # gas: connectorInboundGasStipend
               reply SUCCESS with returned bytes
```

The reply is enqueued (outbound, by `_enqueueReplyMessage`).

### REPLY (`_processReplyMessage`, `:481-545`)

Looks up the original outbound DATA by `replyId`. If found:
- decrement `_connectorInflightCount` and `_connectorQueueCounts`
- delete the outbound message from the queue
- best-effort `IClprApplication.onClprResponse` to the original sender (only
  if sender is exactly 20 bytes and has bytecode)
- if status is `CONNECTOR_NOT_FOUND` or `CONNECTOR_UNDERFUNDED`, **source-side
  slash** the local connector (spec §4.6 outbound table)

## Reentrancy & ordering

- `submitBundle` is guarded by `nonReentrant`.
- All state updates that affect ack/hash/queue are written **before** outbound
  application/connector calls (CEI), or rolled into the in-memory `Channel`
  copy and persisted at the end. Spec §8.5 requires this.
- Application calls have a hard gas cap (`throttles.maxGasPerMessage`).
- Connector inbound notifications have a smaller stipend
  (`economicConfig.connectorInboundGasStipend`) and are best-effort.

## Slashing

Source-side and destination-side slashing tables are spec §4.6. Code path:
`ConnectorLib.slash` does geometric escalation
`basePenalty * penaltyMultiplier^slashCount`, capped at `lockedStake`. If
`slashCount ≥ slashBanThreshold` or stake → 0, the connector is **deleted**
(banned). Slash proceeds go to the bundle submitter, with the
`_transferWithFallback` chain (submitter → owner → `_pendingWithdrawals`).

## Common footguns

- **Empty bundle rejection.** A bundle with no payloads, no anchor change, and
  no ack progress reverts with `EmptyBundle`. Tests that submit zero-payload
  bundles for state-machine transitions must move the trust anchor (set
  `verifier.setNewTrustAnchor(hex"01")`). See `testing.md`.
- **In-memory Channel copy.** `_finishBundle` and helpers mutate a memory
  copy and `_channels[id] = channel` at the end. Don't mix in-place storage
  writes with this pattern — you'll lose updates.
- **DATA messages aren't deleted on ack.** They're deleted when the matching
  REPLY arrives (because the connectorId is needed at REPLY time for
  accounting). `_deleteAckedNonDataMessages` is named accurately.
