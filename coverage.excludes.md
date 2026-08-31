# Coverage Excludes: Defensive, Unreachable Reverts

This document lists code paths that are intentionally unreachable during normal/proper protocol operation and therefore are excluded from coverage expectations. These are defensive guards that protect against impossible or already-prevented states (e.g., invariants enforced elsewhere, prior validation, or spec-mandated sequencing). Hitting them in tests would either require violating the protocol’s trust model, mocking impossible states, or white-boxing internal storage beyond the contract’s public API.

Scope and intent:
- These items should not count against coverage goals. They remain in code for safety-hardening and future-proofing but are not expected to be exercised by black-box or integration tests.
- We still cover and assert the primary/expected error paths; only the truly defensive “should never happen” reverts are listed here.

Excluded defensive reverts

1) src/libraries/BundleLib.sol::_validateAndPrepare
   - Location: Step 1, channel lookup / status check
     - Code: reject PENDING and CLOSED
       - if (channel.status == ClprTypes.ChannelStatus.CLOSED || channel.status == ClprTypes.ChannelStatus.PENDING) {
           revert ClprTypes.ClprInvalidChannelStatus();
         }
   - Rationale: Under the protocol, PENDING records are not present in _channels for bundle processing; CLOSED cannot accept bundles. Presence here would imply corruption or an impossible interleaving. Guard preserved per spec §2.1.1 and C?-9 fix.

2) src/libraries/BundleLib.sol::_validateAndPrepare
   - Location: Step 7, response ordering pre-scan (CLOSING + out-of-order)
     - Code path:
       - if (_checkResponseOrdering(...)) {
           if (channel.status == ClprTypes.ChannelStatus.CLOSING) {
             revert ClprTypes.ClprBundleVerificationFailed();
           }
         }
   - Rationale: Ordering and state machine elsewhere ensure CLOSING is not paired with out-of-order responses for valid bundles. This branch is a strict defensive enforce-per-spec (§4.5). Exercising it requires constructing invalid proofs, which crosses verifier trust assumptions.

3) src/logic/MessagingLogic.sol::sendMessage
   - Location: peer payload limit presence guard (defensive)
     - Code:
       // (should never happen post-fix, but guard defensively)
       if (channel.peerThrottles.maxMessagePayloadBytes == 0) revert ClprTypes.ClprPayloadTooLarge();
   - Rationale: peerThrottles is populated during channel completion from verified config; zero denotes an uninitialized state that normal flows cannot reach. The check is retained as a belt-and-suspenders guard.

Notes
- These defensive branches are kept to simplify reasoning about invariants and to fail fast if assumptions are ever violated due to future changes.
- If at any point we introduce testing utilities to fabricate invalid or intermediate storage states, we may add targeted unit tests to touch these lines; until then, they are excluded from coverage expectations.

Process for updates
- When adding new defensive, unreachable reverts, briefly annotate the site with a comment explaining why it is unreachable under the protocol’s guarantees, and add an entry here following the format above (file :: function, short snippet, short rationale).