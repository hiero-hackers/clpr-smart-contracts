// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprProtobufHelpers as PB} from "@hiero-ledger/clpr/libraries/codec/ClprProtobufHelpers.sol";
import {ClprStateProof} from "@hiero-ledger/clpr/libraries/proof/hiero/ClprStateProof.sol";
import {ClprMerkleProof} from "@hiero-ledger/clpr/libraries/proof/hiero/ClprMerkleProof.sol";

/// @dev These tests hand-build minimal valid `StateProof` protobuf wire bytes
///      using the encoder helpers from `ClprProtobufHelpers` and assert the
///      decoded struct round-trips fields per `state_proof.proto`. They do not
///      exercise SHA-384 walking — that lives in `ClprMerkleProof.t.sol`.
contract ClprStateProofTest is Test {
    function test_decode_emptyBytes_returnsZeroPathsAndNoBaseFound() public pure {
        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode("");
        assertEq(dec.signature.length, 0);
        assertEq(dec.paths.length, 0);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.Any), type(uint256).max);
    }

    function test_decode_signatureOnly_noPaths() public pure {
        bytes memory sigPayload = hex"01020304deadbeef";
        bytes memory tssSignedBlockProof = PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, sigPayload);
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_SIGNED_BLOCK_PROOF, tssSignedBlockProof);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(keccak256(dec.signature), keccak256(sigPayload));
        assertEq(dec.paths.length, 0);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.Any), type(uint256).max);
    }

    // --- Single MerklePath with state_item_leaf ----------------------------

    function test_decode_singlePath_stateItemLeaf_findFirstStateItem() public pure {
        bytes memory leafBytes = hex"cafe";
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, leafBytes);
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);

        assertEq(dec.paths.length, 1);
        assertEq(keccak256(dec.paths[0].stateItemLeaf), keccak256(leafBytes));
        assertEq(dec.paths[0].explicitHash.length, 0);
        assertEq(dec.paths[0].siblings.length, 0);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.StateItemLeaf), 0);
    }

    function test_decode_singlePath_explicitHash_findFirstHash() public pure {
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_HASH, hex"feedfeed");
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.Hash), 0);
        assertEq(keccak256(dec.paths[0].explicitHash), keccak256(hex"feedfeed"));
    }

    function test_decode_singlePath_blockItemLeaf_notFoundByStateItemPredicate() public pure {
        // block_item_leaf is a valid content variant — `LeafKind.BlockItemLeaf`
        // finds it, but the verifier-relevant `LeafKind.StateItemLeaf` does not.
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_BLOCK_ITEM_LEAF, hex"aa");
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.StateItemLeaf), type(uint256).max);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.BlockItemLeaf), 0);
        assertEq(keccak256(dec.paths[0].blockItemLeaf), keccak256(hex"aa"));
    }

    function test_decode_singlePath_timestampLeaf_notFoundByStateItemPredicate() public pure {
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_TIMESTAMP_LEAF, hex"bb");
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.StateItemLeaf), type(uint256).max);
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.TimestampLeaf), 0);
        assertEq(keccak256(dec.paths[0].timestampLeaf), keccak256(hex"bb"));
    }

    // --- next_path_index ---------------------------------------------------

    function test_decode_path_withNextPathIndex() public pure {
        bytes memory pathBytes = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.MP_HASH, hex"99"),
            PB.encodeVarintField(ClprStateProof.MP_NEXT_PATH_INDEX, 7)
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
        assertEq(uint256(dec.paths[0].nextPathIndex), 7);
    }

    function test_decode_path_nextPathIndexOmitted_decodesAsZero() public pure {
        // protobuf3 default: omitted varint == 0.
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_HASH, hex"99");
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(uint256(dec.paths[0].nextPathIndex), 0);
    }

    // --- SiblingNode is_left / hash ----------------------------------------

    function test_decode_siblingNode_isLeftTrue_andHash() public pure {
        bytes memory sibling = abi.encodePacked(
            PB.encodeVarintField(ClprStateProof.SIB_IS_LEFT, 1), // is_left = true
            PB.encodeBytesField(ClprStateProof.SIB_HASH, hex"4242")
        );
        bytes memory pathBytes = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.MP_HASH, hex"01"),
            PB.encodeBytesField(ClprStateProof.MP_SIBLINGS, sibling)
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths[0].siblings.length, 1);
        assertTrue(dec.paths[0].siblings[0].isLeft, "is_left=true should decode as true");
        assertEq(keccak256(dec.paths[0].siblings[0].hash), keccak256(hex"4242"));
    }

    function test_decode_siblingNode_isLeftOmitted_defaultsFalse() public pure {
        // Omit is_left (protobuf3 default false).
        bytes memory sibling = PB.encodeBytesField(ClprStateProof.SIB_HASH, hex"77");
        bytes memory pathBytes = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.MP_HASH, hex"01"),
            PB.encodeBytesField(ClprStateProof.MP_SIBLINGS, sibling)
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertFalse(dec.paths[0].siblings[0].isLeft);
    }

    function test_decode_siblingNode_unaryClimb_emptyHash() public pure {
        // A sibling with `is_left = true` and `hash` omitted (proto3 default
        // for `bytes` is empty) decodes as a present-but-empty-hash sibling.
        // ClprMerkleProof's walker treats that as a unary climb step.
        // (Going the other way — is_left=false AND hash empty — would
        // serialize to zero bytes, which proto3 would drop entirely.)
        bytes memory sibling = PB.encodeVarintField(ClprStateProof.SIB_IS_LEFT, 1);
        bytes memory pathBytes = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.MP_HASH, hex"01"),
            PB.encodeBytesField(ClprStateProof.MP_SIBLINGS, sibling)
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths[0].siblings.length, 1);
        assertEq(dec.paths[0].siblings[0].hash.length, 0);
        assertTrue(dec.paths[0].siblings[0].isLeft);
    }

    // --- Multiple paths, findFirstPath discriminates by LeafKind ---------

    function test_decode_multiplePaths_findFirstByKind() public pure {
        // paths[0] = timestamp_leaf, paths[1] = state_item_leaf, paths[2] = hash.
        // Each LeafKind predicate hits a different index.
        bytes memory tsLeaf = PB.encodeBytesField(ClprStateProof.MP_TIMESTAMP_LEAF, hex"aa");
        bytes memory stateItem = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"bb");
        bytes memory hashLeaf = PB.encodeBytesField(ClprStateProof.MP_HASH, hex"cc");

        bytes memory stateProof = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.SP_PATHS, tsLeaf),
            PB.encodeBytesField(ClprStateProof.SP_PATHS, stateItem),
            PB.encodeBytesField(ClprStateProof.SP_PATHS, hashLeaf)
        );

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 3);
        assertEq(
            ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.Any),
            0,
            "Any kind should pick the first populated path"
        );
        assertEq(
            ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.TimestampLeaf),
            0,
            "TimestampLeaf should pick paths[0]"
        );
        assertEq(
            ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.StateItemLeaf),
            1,
            "StateItemLeaf should pick paths[1]"
        );
        assertEq(
            ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.Hash), 2, "Hash should pick paths[2]"
        );
    }

    // --- TssSignedBlockProof + paths combined ------------------------------

    function test_decode_signatureAndPaths_together() public pure {
        bytes memory sigPayload = hex"deadbeef";
        bytes memory tssSignedBlockProof = PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, sigPayload);

        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"cafe");

        bytes memory stateProof = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes),
            PB.encodeBytesField(ClprStateProof.SP_SIGNED_BLOCK_PROOF, tssSignedBlockProof)
        );

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(keccak256(dec.signature), keccak256(sigPayload));
        assertEq(dec.paths.length, 1);
        assertEq(keccak256(dec.paths[0].stateItemLeaf), keccak256(hex"cafe"));
        assertEq(ClprMerkleProof.findFirstPath(dec.paths, ClprMerkleProof.LeafKind.StateItemLeaf), 0);
    }

    // --- Unknown fields are skipped ----------------------------------------

    function test_decode_unknownTopLevelField_isSkipped() public pure {
        // Add a field number 99 that the decoder doesn't recognise; it must
        // skip without reverting (proto3 forward-compatibility).
        bytes memory unknown = PB.encodeBytesField(99, hex"ffff");
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"01");
        bytes memory stateProof =
            abi.encodePacked(unknown, PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes), unknown);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
    }

    function test_decode_skipsVarintWireType_atTopLevel() public pure {
        // wireType=0 (varint) at top level hits the `wireType != 2` branch in decode().
        bytes memory varintField = abi.encodePacked(PB.encodeFieldKey(99, 0), PB.encodeVarint(0));
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"01");
        bytes memory wire = abi.encodePacked(varintField, PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes));
        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(wire);
        assertEq(dec.paths.length, 1);
    }

    function test_decode_skipsVarintField_inSignedBlockProof() public pure {
        // A varint field inside signed_block_proof hits the else branch before the signature.
        bytes memory varintField = abi.encodePacked(PB.encodeFieldKey(99, 0), PB.encodeVarint(0));
        bytes memory sbp =
            abi.encodePacked(varintField, PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, hex"abcd"));
        bytes memory wire = PB.encodeBytesField(ClprStateProof.SP_SIGNED_BLOCK_PROOF, sbp);
        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(wire);
        assertEq(keccak256(dec.signature), keccak256(hex"abcd"));
    }

    // These call PB.skipField with wireType=1 which reverts; tests use an external harness
    // so vm.expectRevert can intercept the revert.
    function test_decodeMerklePath_unsupportedWireType_reverts() public {
        ClprStateProofDecodeHarness harness = new ClprStateProofDecodeHarness();
        bytes memory fixed64Field = abi.encodePacked(PB.encodeFieldKey(99, 1), bytes8(0));
        bytes memory wire = PB.encodeBytesField(ClprStateProof.SP_PATHS, fixed64Field);
        vm.expectRevert("Unsupported wire type");
        harness.decode(wire);
    }

    function test_decodeSiblingNode_unsupportedWireType_reverts() public {
        ClprStateProofDecodeHarness harness = new ClprStateProofDecodeHarness();
        bytes memory fixed64Field = abi.encodePacked(PB.encodeFieldKey(99, 1), bytes8(0));
        bytes memory siblingBytes = PB.encodeBytesField(ClprStateProof.MP_SIBLINGS, fixed64Field);
        bytes memory wire = PB.encodeBytesField(ClprStateProof.SP_PATHS, siblingBytes);
        vm.expectRevert("Unsupported wire type");
        harness.decode(wire);
    }

    function test_extractStateItemValue_returnsValue_whenPresent() public pure {
        bytes memory payload = hex"deadbeef";
        bytes memory data = PB.encodeBytesField(ClprStateProof.STATE_ITEM_VALUE_FIELD, payload);
        bytes memory result = ClprStateProof.extractStateItemValue(data);
        assertEq(keccak256(result), keccak256(payload));
    }

    function test_extractStateItemValue_skipsVarintField_returnsEmpty() public pure {
        bytes memory varintField = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(42));
        bytes memory result = ClprStateProof.extractStateItemValue(varintField);
        assertEq(result.length, 0);
    }

    function test_unwrapStateValueField_returnsFirstLenField() public pure {
        bytes memory payload = hex"cafe";
        bytes memory data = PB.encodeBytesField(2, payload);
        bytes memory result = ClprStateProof.unwrapStateValueField(data);
        assertEq(keccak256(result), keccak256(payload));
    }

    function test_unwrapStateValueField_skipsVarintThenReturnsLen() public pure {
        bytes memory varintField = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(1));
        bytes memory lenField = PB.encodeBytesField(2, hex"cafe");
        bytes memory data = abi.encodePacked(varintField, lenField);
        bytes memory result = ClprStateProof.unwrapStateValueField(data);
        assertEq(keccak256(result), keccak256(hex"cafe"));
    }

    // --- Phase 3A: Signature validation branch coverage ---------

    function test_decode_emptyPaths_withSignaturePresent() public pure {
        bytes memory sigPayload = hex"aabbccdd";
        bytes memory tssSignedBlockProof = PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, sigPayload);
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_SIGNED_BLOCK_PROOF, tssSignedBlockProof);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(keccak256(dec.signature), keccak256(sigPayload), "signature should decode");
        assertEq(dec.paths.length, 0, "paths should be empty when none provided");
    }

    function test_decode_signatureNormalization_lengthValidation() public pure {
        // Test that signature is preserved as-is regardless of length (no validation)
        bytes memory shortSig = hex"ff";
        bytes memory longSig = hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

        bytes memory stateProof1 = PB.encodeBytesField(
            ClprStateProof.SP_SIGNED_BLOCK_PROOF, PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, shortSig)
        );
        bytes memory stateProof2 = PB.encodeBytesField(
            ClprStateProof.SP_SIGNED_BLOCK_PROOF, PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, longSig)
        );

        ClprStateProof.StateProofDecoded memory dec1 = ClprStateProof.decode(stateProof1);
        ClprStateProof.StateProofDecoded memory dec2 = ClprStateProof.decode(stateProof2);

        assertEq(keccak256(dec1.signature), keccak256(shortSig), "short signature preserved");
        assertEq(keccak256(dec2.signature), keccak256(longSig), "long signature preserved");
    }

    function test_decode_pathVectorGrowth_multiplePaths() public pure {
        // Test that multiple paths all accumulate correctly in the paths array
        bytes memory path1 = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"01");
        bytes memory path2 = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"02");
        bytes memory path3 = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"03");

        bytes memory stateProof = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.SP_PATHS, path1),
            PB.encodeBytesField(ClprStateProof.SP_PATHS, path2),
            PB.encodeBytesField(ClprStateProof.SP_PATHS, path3)
        );

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 3, "should have 3 paths");
        assertEq(keccak256(dec.paths[0].stateItemLeaf), keccak256(hex"01"));
        assertEq(keccak256(dec.paths[1].stateItemLeaf), keccak256(hex"02"));
        assertEq(keccak256(dec.paths[2].stateItemLeaf), keccak256(hex"03"));
    }

    function test_extractStateItemValue_handlesNoValueField() public pure {
        // When no value field is present, extractStateItemValue returns empty
        bytes memory onlyTypeField = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(42));
        bytes memory result = ClprStateProof.extractStateItemValue(onlyTypeField);
        assertEq(result.length, 0, "should return empty when no value field present");
    }

    function test_unwrapStateValueField_skipsMultipleVarintsBeforeLen() public pure {
        // Test skipping multiple varint fields before finding the length field
        bytes memory varint1 = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(1));
        bytes memory varint2 = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(2));
        bytes memory lenField = PB.encodeBytesField(2, hex"beefbeef");
        bytes memory data = abi.encodePacked(varint1, varint2, lenField);

        bytes memory result = ClprStateProof.unwrapStateValueField(data);
        assertEq(keccak256(result), keccak256(hex"beefbeef"), "should skip varints and return len field");
    }

    // --- Phase 3A: Varint skipping and field number edge cases -----

    /// @dev Test decoding with unknown field numbers at top level (wireType=0, varint).
    /// Unknown varint field numbers should be skipped without reverting (proto3 forward-compat).
    function test_decode_multipleUnknownFields_topLevel() public pure {
        // Use wireType 0 (varint) for unknown fields so they don't get accumulated as paths
        bytes memory unknown1 = abi.encodePacked(PB.encodeFieldKey(100, 0), PB.encodeVarint(0xaaaa));
        bytes memory unknown2 = abi.encodePacked(PB.encodeFieldKey(101, 0), PB.encodeVarint(0xbbbb));
        bytes memory pathBytes = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"cafe");
        bytes memory stateProof =
            abi.encodePacked(unknown1, PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes), unknown2);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1, "should decode valid path despite unknown fields");
        assertEq(keccak256(dec.paths[0].stateItemLeaf), keccak256(hex"cafe"));
    }

    /// @dev Test decoding paths with unknown field numbers.
    /// Unknown field numbers in a path should be skipped without reverting.
    function test_decodeMerklePath_unknownFieldNumbers() public pure {
        bytes memory unknownField = PB.encodeBytesField(99, hex"ffff");
        bytes memory hash = PB.encodeBytesField(ClprStateProof.MP_HASH, hex"deadbeef");
        bytes memory pathBytes = abi.encodePacked(unknownField, hash, unknownField);
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
        assertEq(keccak256(dec.paths[0].explicitHash), keccak256(hex"deadbeef"));
    }

    /// @dev Test sibling node decoding with unknown field numbers interspersed.
    function test_decodeSiblingNode_unknownFields() public pure {
        bytes memory unknownField = PB.encodeBytesField(99, hex"cafe");
        bytes memory isLeft = PB.encodeVarintField(ClprStateProof.SIB_IS_LEFT, 1);
        bytes memory hash = PB.encodeBytesField(ClprStateProof.SIB_HASH, hex"beef");
        bytes memory sibling = abi.encodePacked(unknownField, isLeft, hash, unknownField);

        bytes memory pathBytes = abi.encodePacked(
            PB.encodeBytesField(ClprStateProof.MP_HASH, hex"01"),
            PB.encodeBytesField(ClprStateProof.MP_SIBLINGS, sibling)
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths[0].siblings.length, 1);
        assertTrue(dec.paths[0].siblings[0].isLeft);
        assertEq(keccak256(dec.paths[0].siblings[0].hash), keccak256(hex"beef"));
    }

    /// @dev Test varints with continuation bytes (varint encoding edge case).
    /// Varints can span multiple bytes; test decoding of multi-byte varints.
    function test_decode_multiByteVarint_fieldNumber() public pure {
        // Field number 127 (requires 2 bytes in varint encoding: 0xFF 0x00)
        // Create a varint field with high field number
        bytes memory highFieldNum = abi.encodePacked(PB.encodeFieldKey(127, 0), PB.encodeVarint(42));
        bytes memory path = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"cc");
        bytes memory stateProof = abi.encodePacked(highFieldNum, PB.encodeBytesField(ClprStateProof.SP_PATHS, path));

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1, "should skip high field number and decode path");
    }

    /// @dev Test wireType skipping: wireType=0 (varint) at top level.
    /// Should call PB.skipField and continue without reverting.
    function test_decode_wireType0_skipsCorrectly() public pure {
        bytes memory varint = abi.encodePacked(PB.encodeFieldKey(99, 0), PB.encodeVarint(12345));
        bytes memory path = PB.encodeBytesField(ClprStateProof.MP_STATE_ITEM_LEAF, hex"dd");
        bytes memory stateProof = abi.encodePacked(varint, PB.encodeBytesField(ClprStateProof.SP_PATHS, path));

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1);
        assertEq(keccak256(dec.paths[0].stateItemLeaf), keccak256(hex"dd"));
    }

    /// @dev Test wireType skipping in SignedBlockProof decoder.
    /// wireType=0 should skip via PB.skipField.
    function test_decodeSignedBlockProof_wireType0_skipped() public pure {
        bytes memory varint = abi.encodePacked(PB.encodeFieldKey(99, 0), PB.encodeVarint(999));
        bytes memory sig = PB.encodeBytesField(ClprStateProof.SBP_BLOCK_SIGNATURE, hex"abcd");
        bytes memory sbp = abi.encodePacked(varint, sig);
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_SIGNED_BLOCK_PROOF, sbp);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(keccak256(dec.signature), keccak256(hex"abcd"));
    }

    /// @dev Test extractStateItemValue skipping multiple varint fields.
    function test_extractStateItemValue_skipsMultipleVarints() public pure {
        bytes memory varint1 = abi.encodePacked(PB.encodeFieldKey(1, 0), PB.encodeVarint(10));
        bytes memory varint2 = abi.encodePacked(PB.encodeFieldKey(2, 0), PB.encodeVarint(20));
        bytes memory value = PB.encodeBytesField(ClprStateProof.STATE_ITEM_VALUE_FIELD, hex"cafebabe");
        bytes memory data = abi.encodePacked(varint1, varint2, value);

        bytes memory result = ClprStateProof.extractStateItemValue(data);
        assertEq(keccak256(result), keccak256(hex"cafebabe"));
    }

    // --- Phase 2A: Protobuf Parsing Edge Cases (wireType handling) ---------

    /// @notice Test wireType != 2 in _decodeSignedBlockProofSignature (line 125-127).
    /// @dev When signature field has wireType 0 (varint) instead of 2, decoder skips it.
    function test_decodeSignedBlockProof_varintWireType_skipped() public pure {
        bytes memory varintField = abi.encodePacked(
            PB.encodeFieldKey(ClprStateProof.SBP_BLOCK_SIGNATURE, 0), // wireType 0
            PB.encodeVarint(42)
        );
        bytes memory tssSignedBlockProof = varintField;
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_SIGNED_BLOCK_PROOF, tssSignedBlockProof);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.signature.length, 0, "varint field should be skipped");
    }

    /// @notice Test wireType != 2 in _decodeMerklePath (line 162-164).
    /// @dev When path field has wireType 0, must skip without error.
    function test_decodeMerklePath_varintWireType_skipped() public pure {
        bytes memory pathBytes = abi.encodePacked(
            PB.encodeFieldKey(ClprStateProof.MP_HASH, 0), // wireType 0 - wrong!
            PB.encodeVarint(99)
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1, "path should be created");
        assertEq(dec.paths[0].explicitHash.length, 0, "hash should be empty");
    }

    /// @notice Test wireType 0 field skipping within MerklePath (line 141-162).
    /// @dev When merklePath has varint field (wireType 0), it's skipped in the else branch.
    function test_decodeMerklePath_internaldVarintWireType() public pure {
        // Varint field at top level of path - should be handled correctly
        bytes memory pathBytes = abi.encodePacked(
            PB.encodeFieldKey(99, 0), // Unknown field in path, wireType 0
            PB.encodeVarint(123),
            PB.encodeBytesField(ClprStateProof.MP_HASH, hex"deadbeef") // Valid field
        );
        bytes memory stateProof = PB.encodeBytesField(ClprStateProof.SP_PATHS, pathBytes);

        ClprStateProof.StateProofDecoded memory dec = ClprStateProof.decode(stateProof);
        assertEq(dec.paths.length, 1, "path should be created");
        assertEq(keccak256(dec.paths[0].explicitHash), keccak256(hex"deadbeef"), "hash should decode after skip");
    }
}

/// @dev External wrapper so vm.expectRevert can catch reverts from ClprStateProof.decode()
///      when it encounters an unsupported protobuf wire type in a nested decoder.
contract ClprStateProofDecodeHarness {
    function decode(bytes memory wire) external pure returns (ClprStateProof.StateProofDecoded memory) {
        return ClprStateProof.decode(wire);
    }
}
