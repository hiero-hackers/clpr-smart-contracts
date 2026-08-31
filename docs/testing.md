# Testing Guide

Read this before writing or modifying tests. Pairs with `architecture.md`
(for the system under test) and `bundle-flow.md` (for what bundle tests
exercise).

Foundry / `forge test`. All tests live under `test/`.

## Test file map

| File | Covers |
|---|---|
| `Integration.t.sol` | Single happy-path: register-connector → sendMessage → submitBundle (DATA + REPLY) → closeChannel |
| `ClprService.t.sol` | Channel commit/reveal; sendMessage gating (queue, payload, reentrancy); config validation; redactMessage; pull-payment via `CollectPendingTest` + `ClprServiceHarness.seedPending` |
| `BundleProcessor.t.sol` | The heaviest file. ~25 scenarios: verifier failure, replay, hash mismatch, ack misbehavior, PAUSE/auto-resume, full ACTIVE→CLOSING→DRAINED→CLOSED, all reply statuses, source-side slashing, trust-anchor rotation, multi-message bundles, size guards |
| `logic/ConnectorLogic.t.sol` | Self-authenticating commit/reveal happy/sad paths; replay protection; in-flight removal guard; stake top-up (merged `ConnectorLogic.t.sol` + former `ConnectorManager.t.sol`) |
| `logic/AdminLogic.t.sol` | Endpoint bond accounting, key-length validation, deregister/reregister, counters (former `EndpointManager.t.sol`); ledger/economic config validation (former `ClprService/ClprService_Configuration.t.sol`); kill switch; collectPending pull-payment |
| `logic/ChannelLogic.t.sol` | Channel commit/reveal; close/closing lifecycle; peer endpoint roster population at completeChannel (former `test/ClprService/ClprService_Channel.t.sol` + `PeerEndpointRoster.t.sol`) |
| `logic/MessagingLogic.t.sol` | sendMessage gating (queue, quota, payload, reentrancy); redactMessage (former `MessagingLogic.t.sol` + `ClprService/ClprService_Messaging.t.sol` + `ClprService/ClprService_Redaction.t.sol`) |
| `logic/bundle-logic/*.t.sol` | Split by concern: HappyPath, Ordering (incl. source-side slashing), ClosingLogic, ErrorHandling, Configuration (incl. CONTROL-message roster refresh), PaymentPolicy, RateLimiting, TrustAnchor |
| `ClprService_Constructor.t.sol` | Constructor guards (zero logic address, module not deployed) — behavior owned directly by `ClprService.sol`, not delegated |
| `ClprService_ViewSmoke.t.sol` | Smoke test of every read-only getter across all modules |
| `ClprService_GasBenchmark.t.sol` | Gas benchmarks across all modules |
| `ConnectorLib.t.sol` | B8 (pull-payment when both recipient + fallback reject) and B9 (auto-ban on stake-zero) regressions, via `ConnectorLibHarness` |
| `ClprProtobuf.t.sol` | Round-trip + fuzz for DATA / REPLY / CONTROL; running-hash determinism |
| `ClprProtobufHelpers.t.sol` | Varint / field-key / length-delimited primitives |
| `StubBundleContentVerifier.t.sol` | Pass-through decoding via `ClprProtobuf.decodeBundleContent`; defaults |

## Verifier taxonomy (this trips people up)

There are three implementations of `IClprVerifier` in the test tree. The
naming is slightly misleading.

| Name | Path | Role | Use it when |
|---|---|---|---|
| `MockClprVerifier` | `test/mocks/MockClprVerifier.sol` | Pure setter-driven mock; ignores `proofBytes`, returns canned `(metadata, payloads, anchor)` | Most tests. You want to control bundle metadata directly without producing protobuf bytes. |
| `StubBundleContentVerifier` | `test/StubBundleContentVerifier.sol` (production-shaped fixture, lives in `test/` root not `mocks/`) | Decodes `proofBytes` *as* a canonical `ClprBundleContent` protobuf via `ClprProtobuf.decodeBundleContent`. No prefix, no signature, empty trust anchor | Hiero-to-Hiero "stub" bring-up scenarios where the bundle bytes are themselves the canonical proto |
| `StubClprVerifier` | `test/mocks/StubClprVerifier.sol` (test-only; not deployed) | Decodes `"CLPRSTUB" ‖ protobuf(ClprBundleContent)` (prefixed form) using a hand-rolled decoder with strict wire-type guards | Integration tests that consume bundle bytes from an external `StubProofConstructor` (Java tooling) |

> **Mock vs Stub:** the *Mock* doesn't decode anything. Both *Stubs* are real
> decoders. `StubClprVerifier` exists because external tooling emits the
> prefixed form.

## Test base + helpers

- **`helpers/ClprTestBase.sol`** — abstract `Test` subclass exposing
  `_deriveTestChannelId(pubKey, salt)`. Hard-codes `localChain="eip155:1337"`
  and `peerChain="eip155:1"` (matching the default `MockClprVerifier`
  config). Inherit this for any test that creates channels; otherwise the
  derived id won't match the production derivation and `completeChannel`
  will fail.

- **`helpers/ConnectorRegistrar.sol`** — library; `register(service,
  channelId, seed, connectorContract, admin, stake)` does the entire
  commit/reveal-with-stake dance in one call. Different `seed` values give
  independent connectors.

There is **no** shared throttles / economics helper yet — `_setupDefaultConfig`,
`_defaultThrottles`, `_defaultEconomicConfig` are duplicated across test
files. Tolerable; consolidating is a chore for later.

## Conventional `setUp`

```solidity
contract MyTest is ClprTestBase {
    ClprService service;
    MockClprVerifier verifier;

    function setUp() public {
        service = new ClprService(owner, /*protocolVersion*/ 1, "eip155:1337");
        verifier = new MockClprVerifier();
        verifier.setVerifyConfigResult("eip155:1", hex"AABB", 1000);

        // owner-only config setters
        service.updateLedgerConfiguration(/* serviceAddr, throttles, endpoints[] */);
        service.updateEconomicConfiguration(/* ... */);

        // (1) build channel: derive id, sign keccak256(channelId), complete
        // (2) optionally register a connector via ConnectorRegistrar.register
        // (3) for submitBundle: register the test contract itself as an endpoint
        //     via service.registerEndpoint(64-byte-key); add a receive() fn
    }

    receive() external payable {}
}
```

## Submitting a bundle in a test

1. Encode payloads with `ClprProtobuf.encode*`.
2. Compute the SHA-256 running hash chain.
3. Populate `ClprTypes.QueueMetadata { nextMessageId, sentRunningHash, receivedMessageId, receivedRunningHash, state }`.
4. `verifier.setVerifyBundleResult(meta, msgs)`.
5. `service.submitBundle(channelId, hex"00FF")` — proof bytes are
   arbitrary because `MockClprVerifier` ignores them.

### The empty-bundle gotcha

`BundleLib` rejects bundles where: payloads is empty AND ack didn't move AND
trust anchor didn't change (`EmptyBundle`). When testing pure state-machine
transitions with no messages and no ack progress, set
`verifier.setNewTrustAnchor(hex"01")` so the bundle has *some* effect. See
`BundleProcessor.t.sol` lines 379, 408, 434, 530.

## White-box state seeding

There is no broad pattern for poking internal state. Two narrow harnesses:

- `ClprServiceHarness` (in `ClprService.t.sol:14-22`) seeds `_pendingWithdrawals`.
- `ConnectorLibHarness` (in `ConnectorLib.t.sol`) drives `ConnectorLib`
  directly with crafted storage.

If you need to seed something else, add a new harness alongside the test
that needs it; do not expose internals on `ClprService` itself.

## Coverage gaps to be aware of

- Only one full integration scenario; alternative E2E paths (multi-bundle
  drain, peer-initiated close, redact-then-bundle) are tested as fragments
  in `BundleProcessor.t.sol`.
- Some tests are tagged `B8`/`B9`/`B10` — these pin specific historical
  bug fixes (auto-ban on stake-zero, pull-payment fallback, redact range-check
  ordering). Don't simplify them away without reading the linked tests.

## StubClprVerifier placement and round-trip test

`StubClprVerifier` lives at `test/mocks/StubClprVerifier.sol`. This is the
correct location — it is a test-only decoder and is not part of any
production deployment. The first-party round-trip test is in
`test/StubClprVerifier.t.sol`. It:

1. Builds a `ClprQueueMetadata` and a list of `ClprMessagePayload` byte arrays
   in Solidity using `ClprProtobuf` encoders.
2. Encodes them via `ClprProtobuf.encodeBundleContent(meta, payloads)`.
3. Prefixes the result with the 8-byte magic `"CLPRSTUB"` to form `proofBytes`.
4. Passes `proofBytes` to `StubClprVerifier.verifyBundle(proofBytes, "")` and
   asserts that the decoded metadata and payloads match the inputs exactly.
