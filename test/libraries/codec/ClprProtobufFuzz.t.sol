// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {ClprProtobufHelpers as PB} from "@hiero-ledger/clpr/libraries/codec/ClprProtobufHelpers.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title ClprProtobuf adversarial fuzz tests
/// @notice Drives random uint64 varint values into protocol fields whose decoder/encoder
///         used to truncate silently. Each test asserts:
///           - in-range values: succeeds and the field round-trips,
///           - out-of-range values: reverts with the documented error.
///         These tests guard the bound checks at ClprProtobuf.sol around lines
///         50, 149, 208, 282, 386 (encodeControlMessage seconds, decodeReplyMessage status,
///         decodeControlMessage protocolVersion, decodeControlMessage port, decodeBundleContent state).
contract ClprProtobufFuzzTest is Test {
    // ── External wrappers so vm.expectRevert can intercept pure-library reverts ─
    function _decodeReplyExternal(bytes memory p) external pure {
        ClprProtobuf.decodeReplyMessage(p);
    }

    function _decodeControlExternal(bytes memory p) external pure {
        ClprProtobuf.decodeControlMessage(p);
    }

    function _decodeBundleContentExternal(bytes calldata p) external pure {
        ClprProtobuf.decodeBundleContent(p);
    }
    /// @dev Returning variant so the success branch can read the decoded value back.

    function _decodeBundleContentResult(bytes calldata p)
        external
        pure
        returns (ClprTypes.QueueMetadata memory, bytes[] memory)
    {
        return ClprProtobuf.decodeBundleContent(p);
    }

    function _encodeControlExternal(ClprTypes.LedgerConfiguration memory c) external pure {
        ClprProtobuf.encodeControlMessage(c);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────
    /// @dev Wraps `innerCfg` LedgerConfiguration bytes in the full
    ///      ClprMessagePayload(field 3) → ClprControlMessage(field 1) →
    ///      ClprConfigUpdate(field 1) → LedgerConfiguration nesting.
    function _wrapAsControlPayload(bytes memory innerCfg) internal pure returns (bytes memory) {
        bytes memory configUpdate = abi.encodePacked(PB.encodeFieldKey(1, 2), PB.encodeLengthDelimited(innerCfg));
        bytes memory innerCtrl = abi.encodePacked(PB.encodeFieldKey(1, 2), PB.encodeLengthDelimited(configUpdate));
        return abi.encodePacked(PB.encodeFieldKey(3, 2), PB.encodeLengthDelimited(innerCtrl));
    }

    // ── Fix #1: encodeControlMessage rejects nanosSinceEpoch with seconds > uint64 max ──
    function testFuzz_encodeControlMessage_rejectsSecondsOverflow(uint96 ns) public {
        ClprTypes.LedgerConfiguration memory cfg;
        cfg.nanosSinceEpoch = ns;

        uint256 secondsValue = uint256(ns) / 1_000_000_000;
        if (secondsValue > type(uint64).max) {
            vm.expectRevert(ClprTypes.ClprInvalidConfiguration.selector);
            this._encodeControlExternal(cfg);
        } else {
            bytes memory enc = ClprProtobuf.encodeControlMessage(cfg);
            assertGt(enc.length, 0);
        }
    }

    // ── Fix #2: decodeReplyMessage rejects out-of-range ReplyStatus ─────────────
    function testFuzz_decodeReplyMessage_rejectsOutOfRangeStatus(uint64 statusVal) public {
        // ClprReplyMessage = { messageId=1 varint, status=2 varint, replyData=3 bytes }
        bytes memory innerReply = abi.encodePacked(
            PB.encodeVarintField(1, 7), // messageId = 7
            PB.encodeFieldKey(2, 0),
            PB.encodeVarint(statusVal) // raw uint64 status
        );
        // Wrap in ClprMessagePayload field 2 (REPLY)
        bytes memory payload = abi.encodePacked(PB.encodeFieldKey(2, 2), PB.encodeLengthDelimited(innerReply));

        uint64 maxValid = uint64(uint8(type(ClprTypes.ReplyStatus).max));
        if (statusVal > maxValid) {
            vm.expectRevert(ClprTypes.ClprBundleVerificationFailed.selector);
            this._decodeReplyExternal(payload);
        } else {
            ClprTypes.DecodedReply memory r = ClprProtobuf.decodeReplyMessage(payload);
            assertEq(uint256(r.status), uint256(statusVal));
            assertEq(r.messageId, 7);
        }
    }

    // ── Fix #3: decodeControlMessage rejects protocolVersion > uint32 max ───────
    function testFuzz_decodeControlMessage_rejectsProtocolVersionOverflow(uint64 v) public {
        bytes memory innerCfg = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(v));
        bytes memory payload = _wrapAsControlPayload(innerCfg);

        if (v > type(uint32).max) {
            vm.expectRevert(ClprTypes.ClprBundleVerificationFailed.selector);
            this._decodeControlExternal(payload);
        } else {
            ClprTypes.DecodedControl memory c = ClprProtobuf.decodeControlMessage(payload);
            assertEq(uint64(c.config.protocolVersion), v);
        }
    }

    // NOTE: testFuzz_decodeControlMessage_rejectsPortOverflow removed — endpoints (and their nested
    // ServiceEndpoint port) are no longer part of LedgerConfiguration. Port
    // bounds are enforced where the ClprEndpointManifest is decoded (covered by the manifest test suite).

    // ── Fix #5: decodeBundleContent rejects QueueMetadata.state > enum max ──────
    function testFuzz_decodeBundleContent_rejectsOutOfRangeState(uint64 stateVal) public {
        // QueueMetadata field 5 = state varint
        bytes memory metaBytes = abi.encodePacked(PB.encodeFieldKey(5, 0), PB.encodeVarint(stateVal));
        // BundleContent field 1 = metadata LEN
        bytes memory bundle = abi.encodePacked(PB.encodeFieldKey(1, 2), PB.encodeLengthDelimited(metaBytes));

        uint64 maxValid = uint64(uint8(type(ClprTypes.ChannelStatus).max));
        if (stateVal > maxValid) {
            vm.expectRevert(ClprTypes.ClprBundleVerificationFailed.selector);
            this._decodeBundleContentExternal(bundle);
        } else {
            (ClprTypes.QueueMetadata memory m,) = this._decodeBundleContentResult(bundle);
            assertEq(uint64(m.state), stateVal);
        }
    }

    // ── Coverage: decodeBundleContent skips unknown metadata fields (mp = PB.skipField) ──
    function test_decodeBundleContent_unknownMetadataField_reverts() public {
        // Build QueueMetadata with known fields and an extra unknown field 99 (LEN)
        bytes memory metaBytes = abi.encodePacked(
            PB.encodeVarintField(1, uint64(7)), // next_message_id
            PB.encodeBytesField(2, abi.encodePacked(bytes32(uint256(0x11)))), // sent_running_hash (32 bytes)
            PB.encodeVarintField(3, uint64(5)), // received_message_id
            PB.encodeBytesField(4, abi.encodePacked(bytes32(uint256(0x22)))), // received_running_hash (32 bytes)
            PB.encodeVarintField(5, uint64(uint8(ClprTypes.ChannelStatus.ACTIVE))), // state
            PB.encodeBytesField(99, hex"AA") // unknown metadata field
        );
        // Wrap into BundleContent with only field 1 (metadata)
        bytes memory bundle = abi.encodePacked(PB.encodeFieldKey(1, 2), PB.encodeLengthDelimited(metaBytes));

        vm.expectRevert(abi.encodeWithSelector(ClprTypes.ClprUnknownWireField.selector, 99));
        this._decodeBundleContentResult(bundle);
    }
}
