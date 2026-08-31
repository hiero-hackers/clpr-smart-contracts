// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {SeiProtoDecoder} from "@hiero-ledger/clpr/verifiers/evm/sei/lib/SeiProtoDecoder.sol";
import {CometBftLib} from "@hiero-ledger/clpr/libraries/proof/cometbft/CometBftLib.sol";
import {Ics23Lib} from "@hiero-ledger/clpr/libraries/proof/cometbft/Ics23Lib.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobufHelpers as PB} from "@hiero-ledger/clpr/libraries/codec/ClprProtobufHelpers.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Harness: exposes all SeiProtoDecoder internal library functions as external
// ─────────────────────────────────────────────────────────────────────────────

contract SeiProtoDecoderHarness {
    function parseBundlePayload(bytes memory data)
        external
        pure
        returns (
            bytes memory stateProof,
            bytes memory bundleContent,
            bytes memory nextValidatorSet,
            bytes[] memory priorUpdates
        )
    {
        return SeiProtoDecoder.parseBundlePayload(data);
    }

    function parseConfigPayload(bytes memory data)
        external
        pure
        returns (bytes memory validatorSet, uint64 initialHeight, bytes memory ledgerConfig, bytes memory stateProof)
    {
        return SeiProtoDecoder.parseConfigPayload(data);
    }

    function parseStateProof(bytes memory data)
        external
        pure
        returns (
            bytes memory signedHeader,
            bytes memory storeKey,
            bytes memory multistoreProof,
            bytes[] memory storageProofEntries
        )
    {
        return SeiProtoDecoder.parseStateProof(data);
    }

    function parseSignedHeader(bytes memory data)
        external
        pure
        returns (CometBftLib.SeiHeader memory header, CometBftLib.SeiCommit memory commit)
    {
        return SeiProtoDecoder.parseSignedHeader(data);
    }

    function parseHeader(bytes memory data) external pure returns (CometBftLib.SeiHeader memory h) {
        return SeiProtoDecoder.parseHeader(data);
    }

    function parseTimestamp(bytes memory data) external pure returns (int64 seconds_, int32 nanos_) {
        return SeiProtoDecoder.parseTimestamp(data);
    }

    function parseBlockId(bytes memory data)
        external
        pure
        returns (bytes32 hash_, uint32 partTotal_, bytes32 partHash_)
    {
        return SeiProtoDecoder.parseBlockId(data);
    }

    function parsePartSetHeader(bytes memory data) external pure returns (uint32 total_, bytes32 hash_) {
        return SeiProtoDecoder.parsePartSetHeader(data);
    }

    function parseCommit(bytes memory data) external pure returns (CometBftLib.SeiCommit memory c) {
        return SeiProtoDecoder.parseCommit(data);
    }

    function parseCommitSig(bytes memory data) external pure returns (CometBftLib.CommitSig memory sig) {
        return SeiProtoDecoder.parseCommitSig(data);
    }

    function parseValidatorSet(bytes memory data) external pure returns (CometBftLib.SeiValidator[] memory validators) {
        return SeiProtoDecoder.parseValidatorSet(data);
    }

    function parseValidatorEntry(bytes memory data) external pure returns (CometBftLib.SeiValidator memory v) {
        return SeiProtoDecoder.parseValidatorEntry(data);
    }

    function parseValidatorSetUpdate(bytes memory data)
        external
        pure
        returns (
            CometBftLib.SeiValidator[] memory currentValidators,
            bytes memory signedHeaderBytes,
            CometBftLib.SeiValidator[] memory nextValidators,
            bool hasNextValidators
        )
    {
        return SeiProtoDecoder.parseValidatorSetUpdate(data);
    }

    function parseStorageProofEntry(bytes memory data)
        external
        pure
        returns (bytes memory key, bytes memory value, bytes memory iavlProof)
    {
        return SeiProtoDecoder.parseStorageProofEntry(data);
    }

    function parseLedgerConfiguration(bytes memory data)
        external
        pure
        returns (
            string memory chainId,
            bytes20 serviceAddr,
            uint96 configNanos,
            ClprTypes.Throttles memory throttles,
            ClprTypes.Endpoint[] memory endpoints
        )
    {
        return SeiProtoDecoder.parseLedgerConfiguration(data);
    }

    function parseThrottles(bytes memory data) external pure returns (ClprTypes.Throttles memory t) {
        return SeiProtoDecoder.parseThrottles(data);
    }

    function parseExistenceProof(bytes memory data) external pure returns (Ics23Lib.ExistenceProof memory proof) {
        return SeiProtoDecoder.parseExistenceProof(data);
    }

    function parseCommitmentProof(bytes memory data)
        external
        pure
        returns (bool isExistence, Ics23Lib.ExistenceProof memory ep, Ics23Lib.NonExistenceProof memory nep)
    {
        return SeiProtoDecoder.parseCommitmentProof(data);
    }

    function parseNonExistenceProof(bytes memory data) external pure returns (Ics23Lib.NonExistenceProof memory nep) {
        return SeiProtoDecoder.parseNonExistenceProof(data);
    }

    function parseExistenceProofInner(bytes memory data) external pure returns (Ics23Lib.ExistenceProof memory proof) {
        return SeiProtoDecoder.parseExistenceProofInner(data);
    }

    function parseLeafOp(bytes memory data) external pure returns (Ics23Lib.LeafOp memory leaf) {
        return SeiProtoDecoder.parseLeafOp(data);
    }

    function parseInnerOp(bytes memory data) external pure returns (Ics23Lib.InnerOp memory op) {
        return SeiProtoDecoder.parseInnerOp(data);
    }

    function load32(bytes memory data, uint256 offset) external pure returns (bytes32) {
        return SeiProtoDecoder.load32(data, offset);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tests
// ─────────────────────────────────────────────────────────────────────────────

contract SeiProtoDecoderTest is Test {
    SeiProtoDecoderHarness internal harness;

    bytes32 internal constant HASH_A = keccak256("hash-a");
    bytes32 internal constant HASH_B = keccak256("hash-b");
    bytes32 internal constant PUB_KEY = keccak256("ed25519-pub-key");

    function setUp() public {
        harness = new SeiProtoDecoderHarness();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  load32
    // ─────────────────────────────────────────────────────────────────────────

    function test_load32_success_atOffset0() public view {
        bytes memory data = abi.encodePacked(HASH_A);
        assertEq(harness.load32(data, 0), HASH_A);
    }

    function test_load32_success_atOffset4() public view {
        bytes memory data = new bytes(36);
        for (uint256 i = 0; i < 32; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            data[i + 4] = bytes1(uint8(i + 1));
        }
        bytes32 result = harness.load32(data, 4);
        assertNotEq(result, bytes32(0));
    }

    function test_load32_outOfBounds_reverts() public {
        bytes memory data = new bytes(31);
        vm.expectRevert(SeiProtoDecoder.Load32OutOfBounds.selector);
        harness.load32(data, 0);
    }

    function test_load32_offsetOutOfBounds_reverts() public {
        bytes memory data = new bytes(32);
        vm.expectRevert(SeiProtoDecoder.Load32OutOfBounds.selector);
        harness.load32(data, 1);
    }

    function test_load32_exactlyEnough_succeeds() public view {
        bytes memory data = new bytes(32);
        harness.load32(data, 0); // must not revert
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseTimestamp
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseTimestamp_empty_returnsZero() public view {
        (int64 secs, int32 nanos) = harness.parseTimestamp("");
        assertEq(secs, 0);
        assertEq(nanos, 0);
    }

    function test_parseTimestamp_secondsOnly() public view {
        bytes memory data = PB.encodeVarintField(1, uint64(1_700_000_000));
        (int64 secs, int32 nanos) = harness.parseTimestamp(data);
        assertEq(secs, 1_700_000_000);
        assertEq(nanos, 0);
    }

    function test_parseTimestamp_nanosOnly() public view {
        bytes memory data = PB.encodeVarintField(2, uint64(500_000));
        (int64 secs, int32 nanos) = harness.parseTimestamp(data);
        assertEq(secs, 0);
        assertEq(nanos, 500_000);
    }

    function test_parseTimestamp_bothFields() public view {
        bytes memory data =
            abi.encodePacked(PB.encodeVarintField(1, uint64(1_700_000_000)), PB.encodeVarintField(2, uint64(12_345)));
        (int64 secs, int32 nanos) = harness.parseTimestamp(data);
        assertEq(secs, 1_700_000_000);
        assertEq(nanos, 12_345);
    }

    function test_parseTimestamp_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeVarintField(99, uint64(999)), PB.encodeVarintField(1, uint64(42)));
        (int64 secs,) = harness.parseTimestamp(data);
        assertEq(secs, 42);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseBlockId
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseBlockId_empty_returnsZero() public view {
        (bytes32 h, uint32 pt, bytes32 ph) = harness.parseBlockId("");
        assertEq(h, bytes32(0));
        assertEq(pt, 0);
        assertEq(ph, bytes32(0));
    }

    function test_parseBlockId_allFields() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, abi.encodePacked(HASH_A)),
            PB.encodeVarintField(2, uint64(7)),
            PB.encodeBytesField(3, abi.encodePacked(HASH_B))
        );
        (bytes32 h, uint32 pt, bytes32 ph) = harness.parseBlockId(data);
        assertEq(h, HASH_A);
        assertEq(pt, 7);
        assertEq(ph, HASH_B);
    }

    function test_parseBlockId_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(9, hex"deadbeef"), PB.encodeVarintField(2, uint64(3)));
        (, uint32 pt,) = harness.parseBlockId(data);
        assertEq(pt, 3);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parsePartSetHeader
    // ─────────────────────────────────────────────────────────────────────────

    function test_parsePartSetHeader_empty_returnsZero() public view {
        (uint32 t, bytes32 h) = harness.parsePartSetHeader("");
        assertEq(t, 0);
        assertEq(h, bytes32(0));
    }

    function test_parsePartSetHeader_allFields() public view {
        bytes memory data =
            abi.encodePacked(PB.encodeVarintField(1, uint64(5)), PB.encodeBytesField(2, abi.encodePacked(HASH_A)));
        (uint32 t, bytes32 h) = harness.parsePartSetHeader(data);
        assertEq(t, 5);
        assertEq(h, HASH_A);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseLeafOp
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseLeafOp_empty_returnsZero() public view {
        Ics23Lib.LeafOp memory leaf = harness.parseLeafOp("");
        assertEq(leaf.hashOp, 0);
        assertEq(leaf.prefix.length, 0);
    }

    function test_parseLeafOp_allFields() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeVarintField(1, uint64(1)), // hashOp
            PB.encodeVarintField(2, uint64(0)), // prehashKey
            PB.encodeVarintField(3, uint64(1)), // prehashValue
            PB.encodeVarintField(4, uint64(1)), // lengthOp
            PB.encodeBytesField(5, hex"00") // prefix
        );
        Ics23Lib.LeafOp memory leaf = harness.parseLeafOp(data);
        assertEq(leaf.hashOp, 1);
        assertEq(leaf.prehashKey, 0);
        assertEq(leaf.prehashValue, 1);
        assertEq(leaf.lengthOp, 1);
        assertEq(leaf.prefix, hex"00");
    }

    function test_parseLeafOp_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeVarintField(1, uint64(2)));
        Ics23Lib.LeafOp memory leaf = harness.parseLeafOp(data);
        assertEq(leaf.hashOp, 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseInnerOp
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseInnerOp_empty_returnsZero() public view {
        Ics23Lib.InnerOp memory op = harness.parseInnerOp("");
        assertEq(op.hashOp, 0);
        assertEq(op.prefix.length, 0);
        assertEq(op.suffix.length, 0);
    }

    function test_parseInnerOp_allFields() public view {
        bytes memory prefix = hex"010203040506";
        bytes memory suffix = new bytes(33);
        bytes memory data = abi.encodePacked(
            PB.encodeVarintField(1, uint64(1)), PB.encodeBytesField(2, prefix), PB.encodeBytesField(3, suffix)
        );
        Ics23Lib.InnerOp memory op = harness.parseInnerOp(data);
        assertEq(op.hashOp, 1);
        assertEq(op.prefix, prefix);
        assertEq(op.suffix, suffix);
    }

    function test_parseInnerOp_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeVarintField(99, uint64(0)), PB.encodeVarintField(1, uint64(1)));
        Ics23Lib.InnerOp memory op = harness.parseInnerOp(data);
        assertEq(op.hashOp, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseExistenceProofInner
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseExistenceProofInner_noPath() public view {
        bytes memory leafBytes = abi.encodePacked(
            PB.encodeVarintField(1, uint64(1)),
            PB.encodeVarintField(2, uint64(0)),
            PB.encodeVarintField(3, uint64(1)),
            PB.encodeVarintField(4, uint64(1)),
            PB.encodeBytesField(5, hex"00")
        );
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, hex"aabb"), PB.encodeBytesField(2, hex"ccdd"), PB.encodeBytesField(3, leafBytes)
        );
        Ics23Lib.ExistenceProof memory proof = harness.parseExistenceProofInner(data);
        assertEq(proof.key, hex"aabb");
        assertEq(proof.value, hex"ccdd");
        assertEq(proof.leaf.hashOp, 1);
        assertEq(proof.path.length, 0);
    }

    function test_parseExistenceProofInner_withOneInnerOp() public view {
        bytes memory leafBytes = abi.encodePacked(
            PB.encodeVarintField(1, uint64(1)),
            PB.encodeVarintField(2, uint64(0)),
            PB.encodeVarintField(3, uint64(1)),
            PB.encodeVarintField(4, uint64(1)),
            PB.encodeBytesField(5, hex"00")
        );
        bytes memory innerBytes = abi.encodePacked(
            PB.encodeVarintField(1, uint64(1)),
            PB.encodeBytesField(2, hex"01020304050607"),
            PB.encodeBytesField(3, new bytes(33))
        );
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, hex"aabb"),
            PB.encodeBytesField(2, hex"ccdd"),
            PB.encodeBytesField(3, leafBytes),
            PB.encodeBytesField(4, innerBytes)
        );
        Ics23Lib.ExistenceProof memory proof = harness.parseExistenceProofInner(data);
        assertEq(proof.key, hex"aabb");
        assertEq(proof.path.length, 1);
        assertEq(proof.path[0].hashOp, 1);
    }

    function test_parseExistenceProofInner_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"deadbeef"), PB.encodeBytesField(1, hex"cafe"));
        Ics23Lib.ExistenceProof memory proof = harness.parseExistenceProofInner(data);
        assertEq(proof.key, hex"cafe");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseExistenceProof (CommitmentProof wrapper)
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseExistenceProof_validWrapper() public view {
        bytes memory epInner =
            abi.encodePacked(PB.encodeBytesField(1, hex"aabbcc"), PB.encodeBytesField(2, hex"ddeeff"));
        bytes memory data = PB.encodeBytesField(1, epInner);
        Ics23Lib.ExistenceProof memory proof = harness.parseExistenceProof(data);
        assertEq(proof.key, hex"aabbcc");
        assertEq(proof.value, hex"ddeeff");
    }

    function test_parseExistenceProof_emptyInput_returnsEmpty() public view {
        // Empty input: no fields parsed, returns zero-value proof
        Ics23Lib.ExistenceProof memory proof = harness.parseExistenceProof("");
        assertEq(proof.key.length, 0);
    }

    function test_parseExistenceProof_wrongField_reverts() public {
        // field 2 is not allowed — must be field 1
        bytes memory epInner = PB.encodeBytesField(1, hex"aabb");
        bytes memory data = PB.encodeBytesField(2, epInner);
        vm.expectRevert(SeiProtoDecoder.OnlyExistenceProofsSupported.selector);
        harness.parseExistenceProof(data);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseCommitmentProof
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseCommitmentProof_existenceProof() public view {
        bytes memory epInner = abi.encodePacked(PB.encodeBytesField(1, hex"aa"), PB.encodeBytesField(2, hex"bb"));
        bytes memory data = PB.encodeBytesField(1, epInner);
        (bool isExistence, Ics23Lib.ExistenceProof memory ep,) = harness.parseCommitmentProof(data);
        assertTrue(isExistence);
        assertEq(ep.key, hex"aa");
    }

    function test_parseCommitmentProof_nonExistenceProof() public view {
        bytes memory nepInner = PB.encodeBytesField(1, hex"cc");
        bytes memory data = PB.encodeBytesField(2, nepInner);
        (bool isExistence,, Ics23Lib.NonExistenceProof memory nep) = harness.parseCommitmentProof(data);
        assertFalse(isExistence);
        assertEq(nep.key, hex"cc");
    }

    function test_parseCommitmentProof_emptyInput_reverts() public {
        vm.expectRevert(SeiProtoDecoder.UnsupportedProofType.selector);
        harness.parseCommitmentProof("");
    }

    function test_parseCommitmentProof_unknownField_reverts() public {
        bytes memory data = PB.encodeBytesField(99, hex"deadbeef");
        // unknown field is skipped, but no existence/non-existence found → UnsupportedProofType
        vm.expectRevert(SeiProtoDecoder.UnsupportedProofType.selector);
        harness.parseCommitmentProof(data);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseNonExistenceProof
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseNonExistenceProof_keyOnly() public view {
        bytes memory data = PB.encodeBytesField(1, hex"abcd");
        Ics23Lib.NonExistenceProof memory nep = harness.parseNonExistenceProof(data);
        assertEq(nep.key, hex"abcd");
        assertFalse(nep.hasLeft);
        assertFalse(nep.hasRight);
    }

    function test_parseNonExistenceProof_withLeft() public view {
        bytes memory leftEp = abi.encodePacked(PB.encodeBytesField(1, hex"1122"), PB.encodeBytesField(2, hex"3344"));
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, hex"2233"), PB.encodeBytesField(2, leftEp));
        Ics23Lib.NonExistenceProof memory nep = harness.parseNonExistenceProof(data);
        assertEq(nep.key, hex"2233");
        assertTrue(nep.hasLeft);
        assertEq(nep.left.key, hex"1122");
        assertFalse(nep.hasRight);
    }

    function test_parseNonExistenceProof_withRight() public view {
        bytes memory rightEp = abi.encodePacked(PB.encodeBytesField(1, hex"5566"), PB.encodeBytesField(2, hex"7788"));
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, hex"4455"), PB.encodeBytesField(3, rightEp));
        Ics23Lib.NonExistenceProof memory nep = harness.parseNonExistenceProof(data);
        assertTrue(nep.hasRight);
        assertEq(nep.right.key, hex"5566");
    }

    function test_parseNonExistenceProof_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, hex"abcd"));
        Ics23Lib.NonExistenceProof memory nep = harness.parseNonExistenceProof(data);
        assertEq(nep.key, hex"abcd");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseCommitSig
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseCommitSig_empty_returnsZero() public view {
        CometBftLib.CommitSig memory sig = harness.parseCommitSig("");
        assertEq(sig.timestampSeconds, 0);
        assertEq(sig.timestampNanos, 0);
        assertEq(sig.signature.length, 0);
    }

    function test_parseCommitSig_allFields() public view {
        bytes memory tsBytes = PB.encodeVarintField(1, uint64(1_700_000_000));
        bytes memory sigBytes = new bytes(64);
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, tsBytes), PB.encodeBytesField(2, sigBytes));
        CometBftLib.CommitSig memory sig = harness.parseCommitSig(data);
        assertEq(sig.timestampSeconds, 1_700_000_000);
        assertEq(sig.signature.length, 64);
    }

    function test_parseCommitSig_unknownField_skipped() public view {
        bytes memory tsBytes = PB.encodeVarintField(1, uint64(42));
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, tsBytes));
        CometBftLib.CommitSig memory sig = harness.parseCommitSig(data);
        assertEq(sig.timestampSeconds, 42);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseCommit
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseCommit_empty_returnsZero() public view {
        CometBftLib.SeiCommit memory c = harness.parseCommit("");
        assertEq(c.round, 0);
        assertEq(c.partSetTotal, 0);
        assertEq(c.signatures.length, 0);
    }

    function test_parseCommit_allFields_twoSigs() public view {
        bytes memory sigBytes = PB.encodeBytesField(2, new bytes(64));
        bytes memory data = abi.encodePacked(
            PB.encodeVarintField(1, uint64(1)), // round
            PB.encodeVarintField(2, uint64(3)), // partSetTotal
            PB.encodeBytesField(3, abi.encodePacked(HASH_A)), // partSetHash
            PB.encodeBytesField(4, hex"C0"), // signersBits
            PB.encodeBytesField(5, sigBytes), // sig 0
            PB.encodeBytesField(5, sigBytes) // sig 1
        );
        CometBftLib.SeiCommit memory c = harness.parseCommit(data);
        assertEq(c.round, 1);
        assertEq(c.partSetTotal, 3);
        assertEq(c.partSetHash, HASH_A);
        assertEq(c.signersBits, hex"C0");
        assertEq(c.signatures.length, 2);
    }

    function test_parseCommit_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeVarintField(1, uint64(5)));
        CometBftLib.SeiCommit memory c = harness.parseCommit(data);
        assertEq(c.round, 5);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseValidatorEntry
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseValidatorEntry_allFields() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)), // ed25519PubKey
            PB.encodeVarintField(2, uint64(500)) // votingPower
        );
        CometBftLib.SeiValidator memory v = harness.parseValidatorEntry(data);
        assertEq(v.ed25519PubKey, PUB_KEY);
        assertEq(v.votingPower, 500);
    }

    function test_parseValidatorEntry_zeroPower() public view {
        bytes memory data = PB.encodeBytesField(1, abi.encodePacked(PUB_KEY));
        CometBftLib.SeiValidator memory v = harness.parseValidatorEntry(data);
        assertEq(v.ed25519PubKey, PUB_KEY);
        assertEq(v.votingPower, 0);
    }

    function test_parseValidatorEntry_wrongKeyLength_reverts() public {
        bytes memory data = PB.encodeBytesField(1, hex"aabbcc"); // only 3 bytes, not 32
        vm.expectRevert(SeiProtoDecoder.InvalidEd25519KeyLength.selector);
        harness.parseValidatorEntry(data);
    }

    function test_parseValidatorEntry_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(99, hex"ff"),
            PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)),
            PB.encodeVarintField(2, uint64(100))
        );
        CometBftLib.SeiValidator memory v = harness.parseValidatorEntry(data);
        assertEq(v.ed25519PubKey, PUB_KEY);
        assertEq(v.votingPower, 100);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseValidatorSet
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseValidatorSet_empty_returnsEmpty() public view {
        CometBftLib.SeiValidator[] memory vs = harness.parseValidatorSet("");
        assertEq(vs.length, 0);
    }

    function test_parseValidatorSet_oneValidator() public view {
        bytes memory entry =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)), PB.encodeVarintField(2, uint64(100)));
        bytes memory data = PB.encodeBytesField(1, entry);
        CometBftLib.SeiValidator[] memory vs = harness.parseValidatorSet(data);
        assertEq(vs.length, 1);
        assertEq(vs[0].ed25519PubKey, PUB_KEY);
        assertEq(vs[0].votingPower, 100);
    }

    function test_parseValidatorSet_twoValidators() public view {
        bytes32 pk2 = keccak256("ed25519-pub-key-2");
        bytes memory entry1 =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)), PB.encodeVarintField(2, uint64(100)));
        bytes memory entry2 =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(pk2)), PB.encodeVarintField(2, uint64(200)));
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, entry1), PB.encodeBytesField(1, entry2));
        CometBftLib.SeiValidator[] memory vs = harness.parseValidatorSet(data);
        assertEq(vs.length, 2);
        assertEq(vs[0].ed25519PubKey, PUB_KEY);
        assertEq(vs[1].ed25519PubKey, pk2);
    }

    function test_parseValidatorSet_unknownField_skipped() public view {
        bytes memory entry = PB.encodeBytesField(1, abi.encodePacked(PUB_KEY));
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, entry));
        CometBftLib.SeiValidator[] memory vs = harness.parseValidatorSet(data);
        assertEq(vs.length, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseValidatorSetUpdate
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseValidatorSetUpdate_currentOnly() public view {
        bytes memory entry =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)), PB.encodeVarintField(2, uint64(100)));
        bytes memory vsBytes = PB.encodeBytesField(1, entry);
        bytes memory data = PB.encodeBytesField(1, vsBytes);
        (CometBftLib.SeiValidator[] memory cur,, CometBftLib.SeiValidator[] memory next, bool hasNext) =
            harness.parseValidatorSetUpdate(data);
        assertEq(cur.length, 1);
        assertFalse(hasNext);
        assertEq(next.length, 0);
    }

    function test_parseValidatorSetUpdate_withNextValidators() public view {
        bytes32 pk2 = keccak256("next-key");
        bytes memory entry1 =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)), PB.encodeVarintField(2, uint64(100)));
        bytes memory entry2 =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(pk2)), PB.encodeVarintField(2, uint64(200)));
        bytes memory vs1 = PB.encodeBytesField(1, entry1);
        bytes memory vs2 = PB.encodeBytesField(1, entry2);
        bytes memory signedHdr = hex"aabb";
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, vs1), PB.encodeBytesField(2, signedHdr), PB.encodeBytesField(3, vs2)
        );
        (CometBftLib.SeiValidator[] memory cur,, CometBftLib.SeiValidator[] memory next, bool hasNext) =
            harness.parseValidatorSetUpdate(data);
        assertEq(cur.length, 1);
        assertTrue(hasNext);
        assertEq(next.length, 1);
        assertEq(next[0].ed25519PubKey, pk2);
    }

    function test_parseValidatorSetUpdate_unknownField_skipped() public view {
        bytes memory entry =
            abi.encodePacked(PB.encodeBytesField(1, abi.encodePacked(PUB_KEY)), PB.encodeVarintField(2, uint64(50)));
        bytes memory vsBytes = PB.encodeBytesField(1, entry);
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, vsBytes));
        (CometBftLib.SeiValidator[] memory cur,,,) = harness.parseValidatorSetUpdate(data);
        assertEq(cur.length, 1);
    }

    function test_parseValidatorSetUpdate_emptyVsBytes1_returnsEmpty() public view {
        // field 1 is absent; hasNext=false
        (CometBftLib.SeiValidator[] memory cur,, CometBftLib.SeiValidator[] memory next,) =
            harness.parseValidatorSetUpdate("");
        assertEq(cur.length, 0);
        assertEq(next.length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseStorageProofEntry
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseStorageProofEntry_empty_returnsEmpty() public view {
        (bytes memory k, bytes memory v, bytes memory p) = harness.parseStorageProofEntry("");
        assertEq(k.length, 0);
        assertEq(v.length, 0);
        assertEq(p.length, 0);
    }

    function test_parseStorageProofEntry_allFields() public view {
        bytes memory key = hex"aabbccdd";
        bytes memory val = abi.encodePacked(HASH_A);
        bytes memory proof = hex"deadbeef";
        bytes memory data =
            abi.encodePacked(PB.encodeBytesField(1, key), PB.encodeBytesField(2, val), PB.encodeBytesField(3, proof));
        (bytes memory k, bytes memory v, bytes memory p) = harness.parseStorageProofEntry(data);
        assertEq(k, key);
        assertEq(v, val);
        assertEq(p, proof);
    }

    function test_parseStorageProofEntry_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, hex"1234"));
        (bytes memory k,,) = harness.parseStorageProofEntry(data);
        assertEq(k, hex"1234");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseThrottles
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseThrottles_empty_returnsZero() public view {
        ClprTypes.Throttles memory t = harness.parseThrottles("");
        assertEq(t.maxMessagesPerBundle, 0);
        assertEq(t.maxMessagePayloadBytes, 0);
    }

    function test_parseThrottles_allFields() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeVarintField(1, uint64(10)),
            PB.encodeVarintField(2, uint64(1024)),
            PB.encodeVarintField(3, uint64(100_000)),
            PB.encodeVarintField(4, uint64(50)),
            PB.encodeVarintField(5, uint64(2048))
        );
        ClprTypes.Throttles memory t = harness.parseThrottles(data);
        assertEq(t.maxMessagesPerBundle, 10);
        assertEq(t.maxMessagePayloadBytes, 1024);
        assertEq(t.maxGasPerMessage, 100_000);
        assertEq(t.maxQueueDepth, 50);
        assertEq(t.maxSyncBytes, 2048);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseLedgerConfiguration
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseLedgerConfiguration_allFields() public view {
        bytes20 serviceAddr = bytes20(address(0xBEEF));
        bytes memory throttleBytes =
            abi.encodePacked(PB.encodeVarintField(1, uint64(5)), PB.encodeVarintField(2, uint64(512)));
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, bytes("sei-chain-1")),
            PB.encodeBytesField(2, abi.encodePacked(serviceAddr)),
            PB.encodeVarintField(3, uint64(123_456_789)),
            PB.encodeBytesField(4, throttleBytes)
        );
        (
            string memory chainId,
            bytes20 sa,
            uint96 nanos,
            ClprTypes.Throttles memory t,
            ClprTypes.Endpoint[] memory eps
        ) = harness.parseLedgerConfiguration(data);
        assertEq(chainId, "sei-chain-1");
        assertEq(sa, serviceAddr);
        assertEq(nanos, 123_456_789);
        assertEq(t.maxMessagesPerBundle, 5);
        assertEq(t.maxMessagePayloadBytes, 512);
        assertEq(eps.length, 0);
    }

    function test_parseLedgerConfiguration_wrongServiceAddrLength_reverts() public {
        // 19-byte address must revert
        bytes memory data = PB.encodeBytesField(2, hex"aabbccddeeff00112233445566778899aabbcc"); // 19 bytes
        vm.expectRevert(SeiProtoDecoder.InvalidServiceAddressLength.selector);
        harness.parseLedgerConfiguration(data);
    }

    function test_parseLedgerConfiguration_unknownField_skipped() public view {
        bytes20 serviceAddr = bytes20(address(0x1234));
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(99, hex"ff"),
            PB.encodeBytesField(1, bytes("chain-id")),
            PB.encodeBytesField(2, abi.encodePacked(serviceAddr))
        );
        (string memory chainId,,,,) = harness.parseLedgerConfiguration(data);
        assertEq(chainId, "chain-id");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseStateProof
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseStateProof_empty_returnsEmpty() public view {
        (bytes memory sh, bytes memory sk, bytes memory mp, bytes[] memory spe) = harness.parseStateProof("");
        assertEq(sh.length, 0);
        assertEq(sk.length, 0);
        assertEq(mp.length, 0);
        assertEq(spe.length, 0);
    }

    function test_parseStateProof_allFields_oneEntry() public view {
        bytes memory signedHeader = hex"aabb";
        bytes memory storeKey = bytes("evm");
        bytes memory msProof = hex"ccdd";
        bytes memory spEntry = hex"eeff";
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, signedHeader),
            PB.encodeBytesField(2, storeKey),
            PB.encodeBytesField(3, msProof),
            PB.encodeBytesField(4, spEntry)
        );
        (bytes memory sh, bytes memory sk, bytes memory mp, bytes[] memory spe) = harness.parseStateProof(data);
        assertEq(sh, signedHeader);
        assertEq(sk, storeKey);
        assertEq(mp, msProof);
        assertEq(spe.length, 1);
        assertEq(spe[0], spEntry);
    }

    function test_parseStateProof_multipleEntries() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(4, hex"0011"), PB.encodeBytesField(4, hex"2233"), PB.encodeBytesField(4, hex"4455")
        );
        (,,, bytes[] memory spe) = harness.parseStateProof(data);
        assertEq(spe.length, 3);
        assertEq(spe[0], hex"0011");
        assertEq(spe[1], hex"2233");
        assertEq(spe[2], hex"4455");
    }

    function test_parseStateProof_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(2, bytes("evm")));
        (, bytes memory sk,,) = harness.parseStateProof(data);
        assertEq(sk, bytes("evm"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseSignedHeader
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseSignedHeader_empty_returnsZeroStructs() public view {
        (CometBftLib.SeiHeader memory h, CometBftLib.SeiCommit memory c) = harness.parseSignedHeader("");
        assertEq(h.height, 0);
        assertEq(c.round, 0);
    }

    function test_parseSignedHeader_headerAndCommit() public view {
        bytes memory headerBytes = PB.encodeVarintField(4, uint64(100)); // height = 100
        bytes memory commitBytes = PB.encodeVarintField(1, uint64(2)); // round = 2
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, headerBytes), PB.encodeBytesField(2, commitBytes));
        (CometBftLib.SeiHeader memory h, CometBftLib.SeiCommit memory c) = harness.parseSignedHeader(data);
        assertEq(h.height, 100);
        assertEq(c.round, 2);
    }

    function test_parseSignedHeader_unknownField_skipped() public view {
        bytes memory headerBytes = PB.encodeVarintField(4, uint64(50));
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, headerBytes));
        (CometBftLib.SeiHeader memory h,) = harness.parseSignedHeader(data);
        assertEq(h.height, 50);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseHeader — all 15 fields
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseHeader_empty_returnsZero() public view {
        CometBftLib.SeiHeader memory h = harness.parseHeader("");
        assertEq(h.height, 0);
        assertEq(h.versionBlock, 0);
    }

    function test_parseHeader_allFields() public view {
        bytes20 proposer = bytes20(address(0xDEAD));
        bytes memory tsBytes = PB.encodeVarintField(1, uint64(1_700_000_000));
        bytes memory lastBlockIdBytes = abi.encodePacked(
            PB.encodeBytesField(1, abi.encodePacked(HASH_A)),
            PB.encodeVarintField(2, uint64(1)),
            PB.encodeBytesField(3, abi.encodePacked(HASH_B))
        );
        bytes memory data = abi.encodePacked(
            PB.encodeVarintField(1, uint64(11)), // versionBlock
            PB.encodeVarintField(2, uint64(1)), // versionApp
            PB.encodeBytesField(3, bytes("sei-chain-1")), // chainId
            PB.encodeVarintField(4, uint64(200)), // height
            PB.encodeBytesField(5, tsBytes), // time
            PB.encodeBytesField(6, lastBlockIdBytes), // lastBlockId
            PB.encodeBytesField(7, abi.encodePacked(HASH_A)), // lastCommitHash
            PB.encodeBytesField(8, abi.encodePacked(HASH_B)), // dataHash
            PB.encodeBytesField(9, abi.encodePacked(HASH_A)), // validatorsHash
            PB.encodeBytesField(10, abi.encodePacked(HASH_B)), // nextValidatorsHash
            PB.encodeBytesField(11, abi.encodePacked(HASH_A)), // consensusHash
            PB.encodeBytesField(12, abi.encodePacked(HASH_B)), // appHash
            PB.encodeBytesField(13, abi.encodePacked(HASH_A)), // lastResultsHash
            PB.encodeBytesField(14, abi.encodePacked(HASH_B)), // evidenceHash
            PB.encodeBytesField(15, abi.encodePacked(proposer)) // proposerAddress
        );
        CometBftLib.SeiHeader memory h = harness.parseHeader(data);
        assertEq(h.versionBlock, 11);
        assertEq(h.versionApp, 1);
        assertEq(h.chainId, "sei-chain-1");
        assertEq(h.height, 200);
        assertEq(h.timeSeconds, 1_700_000_000);
        assertEq(h.lastBlockIdHash, HASH_A);
        assertEq(h.lastBlockIdPartSetTotal, 1);
        assertEq(h.lastBlockIdPartSetHash, HASH_B);
        assertEq(h.lastCommitHash, HASH_A);
        assertEq(h.dataHash, HASH_B);
        assertEq(h.appHash, HASH_B);
        assertEq(h.proposerAddress, proposer);
    }

    function test_parseHeader_invalidProposerLength_reverts() public {
        // proposer address must be exactly 20 bytes
        bytes memory data = PB.encodeBytesField(15, hex"aabbcc"); // only 3 bytes
        vm.expectRevert(SeiProtoDecoder.InvalidProposerAddressLength.selector);
        harness.parseHeader(data);
    }

    function test_parseHeader_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeVarintField(4, uint64(77)));
        CometBftLib.SeiHeader memory h = harness.parseHeader(data);
        assertEq(h.height, 77);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseBundlePayload
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseBundlePayload_empty_returnsEmpty() public view {
        (bytes memory sp, bytes memory bc, bytes memory nvs, bytes[] memory prior) = harness.parseBundlePayload("");
        assertEq(sp.length, 0);
        assertEq(bc.length, 0);
        assertEq(nvs.length, 0);
        assertEq(prior.length, 0);
    }

    function test_parseBundlePayload_allFields() public view {
        bytes memory stateProof = hex"1111";
        bytes memory bundleContent = hex"2222";
        bytes memory nextVS = hex"3333";
        bytes memory prior1 = hex"4444";
        bytes memory prior2 = hex"5555";
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, stateProof),
            PB.encodeBytesField(2, bundleContent),
            PB.encodeBytesField(3, nextVS),
            PB.encodeBytesField(4, prior1),
            PB.encodeBytesField(4, prior2)
        );
        (bytes memory sp, bytes memory bc, bytes memory nvs, bytes[] memory prior) = harness.parseBundlePayload(data);
        assertEq(sp, stateProof);
        assertEq(bc, bundleContent);
        assertEq(nvs, nextVS);
        assertEq(prior.length, 2);
        assertEq(prior[0], prior1);
        assertEq(prior[1], prior2);
    }

    function test_parseBundlePayload_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(99, hex"ff"), PB.encodeBytesField(1, hex"aabb"));
        (bytes memory sp,,,) = harness.parseBundlePayload(data);
        assertEq(sp, hex"aabb");
    }

    function test_parseBundlePayload_noPriorUpdates() public view {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, hex"aa"), PB.encodeBytesField(2, hex"bb"));
        (,, bytes memory nvs, bytes[] memory prior) = harness.parseBundlePayload(data);
        assertEq(nvs.length, 0);
        assertEq(prior.length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  parseConfigPayload
    // ─────────────────────────────────────────────────────────────────────────

    function test_parseConfigPayload_allFields() public view {
        bytes memory vs = hex"aabb";
        bytes memory lc = hex"ccdd";
        bytes memory sp = hex"eeff";
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(1, vs),
            PB.encodeVarintField(2, uint64(42)),
            PB.encodeBytesField(3, lc),
            PB.encodeBytesField(4, sp)
        );
        (bytes memory gotVs, uint64 height, bytes memory gotLc, bytes memory gotSp) = harness.parseConfigPayload(data);
        assertEq(gotVs, vs);
        assertEq(height, 42);
        assertEq(gotLc, lc);
        assertEq(gotSp, sp);
    }

    function test_parseConfigPayload_missingValidatorSet_reverts() public {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(3, hex"cc"), PB.encodeBytesField(4, hex"dd"));
        vm.expectRevert(SeiProtoDecoder.MissingValidatorSet.selector);
        harness.parseConfigPayload(data);
    }

    function test_parseConfigPayload_missingLedgerConfig_reverts() public {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, hex"aa"), PB.encodeBytesField(4, hex"dd"));
        vm.expectRevert(SeiProtoDecoder.MissingLedgerConfig.selector);
        harness.parseConfigPayload(data);
    }

    function test_parseConfigPayload_missingStateProof_reverts() public {
        bytes memory data = abi.encodePacked(PB.encodeBytesField(1, hex"aa"), PB.encodeBytesField(3, hex"cc"));
        vm.expectRevert(SeiProtoDecoder.MissingStateProof.selector);
        harness.parseConfigPayload(data);
    }

    function test_parseConfigPayload_unknownField_skipped() public view {
        bytes memory data = abi.encodePacked(
            PB.encodeBytesField(99, hex"ff"),
            PB.encodeBytesField(1, hex"aa"),
            PB.encodeBytesField(3, hex"cc"),
            PB.encodeBytesField(4, hex"dd")
        );
        (bytes memory vs,,,) = harness.parseConfigPayload(data);
        assertEq(vs, hex"aa");
    }
}
