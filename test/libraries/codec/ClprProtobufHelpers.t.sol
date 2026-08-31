// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprProtobufHelpers} from "@hiero-ledger/clpr/libraries/codec/ClprProtobufHelpers.sol";

contract ClprProtobufHelpersTest is Test {
    function test_encodeVarint_singleByte() public pure {
        bytes memory result = ClprProtobufHelpers.encodeVarint(1);
        assertEq(result.length, 1);
        assertEq(uint8(result[0]), 0x01);
    }

    function test_encodeVarint_zero() public pure {
        bytes memory result = ClprProtobufHelpers.encodeVarint(0);
        assertEq(result.length, 1);
        assertEq(uint8(result[0]), 0x00);
    }

    function test_encodeVarint_twoByte() public pure {
        bytes memory result = ClprProtobufHelpers.encodeVarint(300);
        assertEq(result.length, 2);
        assertEq(uint8(result[0]), 0xAC);
        assertEq(uint8(result[1]), 0x02);
    }

    function test_encodeVarint_maxUint64() public pure {
        bytes memory result = ClprProtobufHelpers.encodeVarint(type(uint64).max);
        assertEq(result.length, 10);
    }

    function test_decodeVarint_singleByte() public pure {
        bytes memory data = hex"01";
        (uint64 value, uint256 newOffset) = ClprProtobufHelpers.decodeVarint(data, 0);
        assertEq(value, 1);
        assertEq(newOffset, 1);
    }

    function test_decodeVarint_twoByte() public pure {
        bytes memory data = hex"AC02";
        (uint64 value, uint256 newOffset) = ClprProtobufHelpers.decodeVarint(data, 0);
        assertEq(value, 300);
        assertEq(newOffset, 2);
    }

    function test_decodeVarint_withOffset() public pure {
        bytes memory data = hex"FFAC02";
        (uint64 value, uint256 newOffset) = ClprProtobufHelpers.decodeVarint(data, 1);
        assertEq(value, 300);
        assertEq(newOffset, 3);
    }

    function test_encodeFieldKey_varint() public pure {
        bytes memory result = ClprProtobufHelpers.encodeFieldKey(1, 0);
        assertEq(result.length, 1);
        assertEq(uint8(result[0]), 0x08);
    }

    function test_encodeFieldKey_lengthDelimited() public pure {
        bytes memory result = ClprProtobufHelpers.encodeFieldKey(1, 2);
        assertEq(result.length, 1);
        assertEq(uint8(result[0]), 0x0A);
    }

    function test_encodeFieldKey_field4() public pure {
        bytes memory result = ClprProtobufHelpers.encodeFieldKey(4, 2);
        assertEq(result.length, 1);
        assertEq(uint8(result[0]), 0x22);
    }

    function test_decodeFieldKey() public pure {
        bytes memory data = hex"0A";
        (uint64 fieldNumber, uint8 wireType, uint256 newOffset) = ClprProtobufHelpers.decodeFieldKey(data, 0);
        assertEq(fieldNumber, 1);
        assertEq(wireType, 2);
        assertEq(newOffset, 1);
    }

    function test_encodeLengthDelimited() public pure {
        bytes memory payload = hex"DEADBEEF";
        bytes memory result = ClprProtobufHelpers.encodeLengthDelimited(payload);
        assertEq(result.length, 5);
        assertEq(uint8(result[0]), 0x04);
        assertEq(result[1], bytes1(0xDE));
    }

    function test_decodeLengthDelimited() public pure {
        bytes memory data = hex"04DEADBEEF";
        (bytes memory payload, uint256 newOffset) = ClprProtobufHelpers.decodeLengthDelimited(data, 0);
        assertEq(payload.length, 4);
        assertEq(payload[0], bytes1(0xDE));
        assertEq(newOffset, 5);
    }

    function test_varint_roundtrip(uint64 value) public pure {
        bytes memory encoded = ClprProtobufHelpers.encodeVarint(value);
        (uint64 decoded,) = ClprProtobufHelpers.decodeVarint(encoded, 0);
        assertEq(decoded, value);
    }

    function test_decodeLengthDelimited_largeCopies() public pure {
        // Build a 96-byte payload (0x60) so the assembly loop copies 3 full 32-byte words
        uint256 len = 96;
        bytes memory payload = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            payload[i] = bytes1(uint8(i));
        }
        // encode: varint(length)=0x60 followed by raw payload
        bytes memory data = abi.encodePacked(bytes1(0x60), payload);
        (bytes memory out, uint256 newOffset) = ClprProtobufHelpers.decodeLengthDelimited(data, 0);

        assertEq(out.length, len, "decoded length mismatch");
        assertEq(newOffset, len + 1, "newOffset should advance by 1 (varint) + len");
        assertEq(keccak256(out), keccak256(payload), "payload bytes must match exactly");
    }

    function test_skipField_revert_unsupportedWireType() public {
        vm.expectRevert(bytes("Unsupported wire type"));
        this.exposedSkipField(hex"00", 0, 3);
    }

    // ── Negative cases: truncation and overflow (bounds-check fix) ─────────────

    function test_decodeVarint_revert_truncated_singleByte() public {
        // Continuation bit set, but no next byte.
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeVarint(hex"80", 0);
    }

    function test_decodeVarint_revert_truncated_multiByte() public {
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeVarint(hex"8080", 0);
    }

    function test_decodeVarint_revert_offsetAtEnd() public {
        // offset == data.length: no byte to read.
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeVarint(hex"01", 1);
    }

    function test_decodeVarint_revert_offsetPastEnd() public {
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeVarint(hex"01", 5);
    }

    function test_decodeVarint_revert_overflow_valueTooWide() public {
        // The tenth byte (0x02) would set bit 64, which a uint64 cannot hold.
        vm.expectRevert(ClprProtobufHelpers.VarintOverflow.selector);
        this.exposedDecodeVarint(hex"ffffffffffffffffff02", 0);
    }

    function test_decodeVarint_revert_overflow_eleventhByte() public {
        // A uint64 never needs an eleventh byte.
        vm.expectRevert(ClprProtobufHelpers.VarintOverflow.selector);
        this.exposedDecodeVarint(hex"80808080808080808080", 0);
    }

    function test_decodeVarint_maxUint64_roundtrip() public pure {
        // The tenth byte 0x01 (bit 63) is the accepted boundary.
        bytes memory encoded = ClprProtobufHelpers.encodeVarint(type(uint64).max);
        (uint64 value, uint256 newOffset) = ClprProtobufHelpers.decodeVarint(encoded, 0);
        assertEq(value, type(uint64).max);
        assertEq(newOffset, 10);
    }

    function test_decodeVarint_nonMinimal_accepted() public pure {
        // 0 encoded in two bytes. Reference protobuf accepts non-minimal encodings.
        (uint64 value, uint256 newOffset) = ClprProtobufHelpers.decodeVarint(hex"8000", 0);
        assertEq(value, 0);
        assertEq(newOffset, 2);
    }

    function test_decodeFieldKey_revert_truncated() public {
        // A key that runs off the end reverts.
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeFieldKey(hex"80", 0);
    }

    function test_decodeLengthDelimited_revert_lengthOneTooLong() public {
        // Declares 5 payload bytes, only 4 follow.
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeLengthDelimited(hex"05DEADBEEF", 0);
    }

    function test_decodeLengthDelimited_revert_lengthFarPastEnd() public {
        // Declares 32 payload bytes, only 2 follow.
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeLengthDelimited(hex"20DEAD", 0);
    }

    function test_decodeLengthDelimited_revert_truncatedLengthPrefix() public {
        // The length prefix itself is a truncated varint.
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeLengthDelimited(hex"80", 0);
    }

    function test_decodeLengthDelimited_zeroLength_atEnd() public pure {
        // A zero-length field at the exact end of the buffer is valid.
        (bytes memory payload, uint256 newOffset) = ClprProtobufHelpers.decodeLengthDelimited(hex"00", 0);
        assertEq(payload.length, 0);
        assertEq(newOffset, 1);
    }

    function test_decodeLengthDelimited_nestedInnerExceedsOuter() public {
        // The outer field copies 3 bytes into `inner`. The inner field then claims 5 bytes.
        // That is more than `inner` holds, so the inner decode reverts.
        (bytes memory inner,) = ClprProtobufHelpers.decodeLengthDelimited(hex"0305DEAD", 0);
        assertEq(inner.length, 3);
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedDecodeLengthDelimited(inner, 0);
    }

    function test_skipField_revert_varintTruncated() public {
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedSkipField(hex"80", 0, 0);
    }

    function test_skipField_revert_lengthPastEnd() public {
        vm.expectRevert(ClprProtobufHelpers.TruncatedInput.selector);
        this.exposedSkipField(hex"05DE", 0, 2);
    }

    function test_skipField_varint_wellFormed() public pure {
        assertEq(ClprProtobufHelpers.skipField(hex"AC02", 0, 0), 2);
    }

    function test_skipField_lengthDelimited_wellFormed() public pure {
        assertEq(ClprProtobufHelpers.skipField(hex"04DEADBEEF", 0, 2), 5);
    }

    /// @dev Invariant: a decode that does not revert never returns an offset past the end.
    function testFuzz_decodeVarint_newOffsetBounded(bytes calldata data, uint256 offset) public view {
        offset = bound(offset, 0, data.length + 8);
        try this.exposedDecodeVarint(data, offset) returns (uint64, uint256 newOffset) {
            assertLe(newOffset, data.length, "newOffset must not exceed data.length");
        } catch {
            // TruncatedInput and VarintOverflow are the allowed failures.
        }
    }

    // ── External wrappers so vm.expectRevert intercepts the library reverts ────

    function exposedSkipField(bytes memory data, uint256 offset, uint8 wireType) external pure returns (uint256) {
        return ClprProtobufHelpers.skipField(data, offset, wireType);
    }

    function exposedDecodeVarint(bytes calldata data, uint256 offset) external pure returns (uint64, uint256) {
        return ClprProtobufHelpers.decodeVarint(data, offset);
    }

    function exposedDecodeFieldKey(bytes calldata data, uint256 offset) external pure returns (uint64, uint8, uint256) {
        return ClprProtobufHelpers.decodeFieldKey(data, offset);
    }

    function exposedDecodeLengthDelimited(bytes calldata data, uint256 offset)
        external
        pure
        returns (bytes memory, uint256)
    {
        return ClprProtobufHelpers.decodeLengthDelimited(data, offset);
    }
}
