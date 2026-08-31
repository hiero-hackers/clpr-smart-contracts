// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {MockClprApplication} from "@test/mocks/MockClprApplication.sol";
import {BundleLogicTestBase} from "@test/logic/bundle-logic/BundleLogicTestBase.sol";

/// @notice Chain-continuity tests for partial (bundle-scoped) bundles.
///
///         A channel's `receivedRunningHash` is a single continuous SHA-256 chain over every
///         inbound message ever delivered. A bundle is bundle-scoped: it may carry only a slice of
///         the sender's queue (e.g. 10 of 100 messages), and `QueueMetadata.sentRunningHash` is that
///         global chain sampled at the bundle's LAST message — not a fresh hash over the slice.
///
///         These tests pin the invariant: delivering N messages across several partial bundles must
///         leave the channel in exactly the same state (`receivedMessageId`, `receivedRunningHash`)
///         as delivering all N in one bundle. Queue depth on the sender side is irrelevant — only the
///         bundle boundary matters (see BundleLib Step 4/5).
contract BundleLogic_PartialBundle is BundleLogicTestBase {
    MockClprApplication internal app;

    function setUp() public override {
        super.setUp();
        app = new MockClprApplication();
        app.setResponse(hex"504F4E47"); // "PONG"
        _registerTestConnector();
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /// @dev Distinct DATA payload for the message with 1-based id `i`.
    function _msg(uint256 i) internal view returns (bytes memory) {
        return ClprProtobuf.encodeDataMessage(
            connectorId,
            abi.encodePacked(address(app)),
            // casting to 'uint32'/'uint8' is safe: test message ids stay in single digits.
            // forge-lint: disable-next-line(unsafe-typecast)
            abi.encodePacked(uint32(i)), // sender varies per message
            // forge-lint: disable-next-line(unsafe-typecast)
            abi.encodePacked("DATA-", uint8(i)) // body varies per message
        );
    }

    /// @dev Global running hash from genesis (id 1) through id `lastId`, matching BundleLib Step 5.
    function _globalHash(uint256 lastId) internal view returns (bytes32 h) {
        h = bytes32(0);
        for (uint256 i = 1; i <= lastId; i++) {
            h = sha256(abi.encodePacked(h, sha256(_msg(i))));
        }
    }

    /// @dev Submit ids [firstId .. firstId+count-1] as one bundle, optionally prefixed by `dupCount`
    ///      leading-duplicate retransmissions (ids firstId-dupCount .. firstId-1). `sentRunningHash`
    ///      is always the global chain through the bundle's last message.
    function _submitSlice(uint64 firstId, uint256 count, uint256 dupCount) internal {
        uint256 total = count + dupCount;
        uint256 startId = uint256(firstId) - dupCount; // first id placed in the array
        bytes[] memory payloads = new bytes[](total);
        for (uint256 k = 0; k < total; k++) {
            payloads[k] = _msg(startId + k);
        }

        // casting to 'uint64' is safe: test bundle sizes stay in single digits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 lastId = firstId + uint64(count) - 1;
        ClprTypes.QueueMetadata memory meta = ClprTypes.QueueMetadata({
            nextMessageId: lastId + 1, // bundle-scoped: last message in THIS bundle + 1
            sentRunningHash: _globalHash(lastId),
            receivedMessageId: 0, // no outbound ack exercised here
            receivedRunningHash: bytes32(0),
            state: ClprTypes.ChannelStatus.ACTIVE,
            endpointManifestVersion: 0
        });
        verifier.setVerifyBundleResult(meta, payloads);
        _submitBundle(hex"00FF");
    }

    // ── Tests ─────────────────────────────────────────────────────────

    /// @notice Two partial bundles [1..3] then [4..6] leave the channel in the same state a single
    ///         6-message bundle would: the running hash of bundle 2 is seeded from bundle 1's result,
    ///         producing the continuous global chain H6.
    function test_partialBundles_matchSingleBundleState() public {
        _submitSlice(1, 3, 0); // deliver messages 1..3
        ClprTypes.Channel memory afterFirst = service.getChannel(channelId);
        assertEq(afterFirst.receivedMessageId, 3, "bundle 1: receivedMessageId");
        assertEq(afterFirst.receivedRunningHash, _globalHash(3), "bundle 1: hash = H3");

        _submitSlice(4, 3, 0); // deliver messages 4..6 (queue could hold arbitrarily more)
        ClprTypes.Channel memory afterSecond = service.getChannel(channelId);

        // Continuity: state equals a single, uninterrupted 6-message delivery.
        assertEq(afterSecond.receivedMessageId, 6, "final receivedMessageId");
        assertEq(afterSecond.receivedRunningHash, _globalHash(6), "final hash = H6 (continuous chain)");
    }

    /// @notice A bundle that retransmits already-received messages 1..3 as leading duplicates ahead of
    ///         new messages 4..6 must skip the duplicates in both the hash chain and dispatch: the
    ///         final hash is still H6 (not double-counted) and no extra replies are queued.
    function test_partialBundle_leadingDuplicatesSkipped_preserveChain() public {
        _submitSlice(1, 3, 0); // deliver 1..3
        ClprTypes.Channel memory afterFirst = service.getChannel(channelId);
        assertEq(afterFirst.nextMessageId, 4, "3 replies queued for 3 DATA messages");

        // Bundle 2 carries [1,2,3,4,5,6]; ids 1..3 are leading duplicates, 4..6 are new.
        // newMessageCount = nextMessageId(7) - expectedFirstId(4) = 3; messageStartIndex = 6 - 3 = 3.
        _submitSlice(4, 3, 3);
        ClprTypes.Channel memory afterSecond = service.getChannel(channelId);

        // Hash: seeded from H3, chained over 4..6 only → H6. Had the duplicates been re-hashed, the
        // computed hash would not equal the verifier's sentRunningHash and Step 5 would have reverted.
        assertEq(afterSecond.receivedMessageId, 6, "receivedMessageId advances past duplicates");
        assertEq(afterSecond.receivedRunningHash, _globalHash(6), "hash continuous through 6, no double-count");

        // Dispatch: duplicates were not re-dispatched, so only 3 new replies were queued (ids 4..6),
        // leaving nextMessageId at 7 rather than 10.
        assertEq(afterSecond.nextMessageId, 7, "duplicates not re-dispatched");
    }

    receive() external payable override {}
}
