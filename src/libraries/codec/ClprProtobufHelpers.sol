// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ClprProtobufHelpers
/// @notice Low-level protobuf wire format primitives for encoding/decoding.
/// @dev Handles varint, field keys, and length-delimited fields per the protobuf3 spec.
///
///      Every read helper fails **closed**: input that runs off the end of the buffer, or
///      that encodes a varint too wide for `uint64`, reverts instead of yielding a
///      zero-padded value and an offset past the end. This matters because callers drive
///      `while (pos < data.length)` loops — a helper that returns a past-the-end offset
///      terminates such a loop as though the message had been fully consumed, so truncated
///      or malformed peer input would otherwise decode "successfully" into partial or
///      attacker-influenced data.
library ClprProtobufHelpers {
    /// @notice A read ran past the end of the buffer: a length prefix or varint extends
    ///         beyond `data`.
    error TruncatedInput();

    /// @notice A varint carries more than 64 bits of value, so decoding it would silently
    ///         discard the high bits.
    error VarintOverflow();

    /// @notice Encode a uint64 as a protobuf varint.
    function encodeVarint(uint64 value) internal pure returns (bytes memory) {
        if (value == 0) return hex"00";

        // Compute byte count with a single pass so we allocate exactly once.
        uint256 len = 0;
        uint64 tmp = value;
        while (tmp > 0) {
            tmp >>= 7;
            len++;
        }

        bytes memory result = new bytes(len);
        uint64 v = value;
        for (uint256 i = 0; i < len; i++) {
            // casting to 'uint8' is safe because `v & 0x7F` is in [0, 127].
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(v & 0x7F);
            v >>= 7;
            if (v > 0) b |= 0x80;
            result[i] = bytes1(b);
        }
        return result;
    }

    /// @notice Decode a protobuf varint from bytes at the given offset.
    /// @dev Reverts `TruncatedInput` if the varint runs off the end of `data` (including an
    ///      `offset` at or past the end), and `VarintOverflow` if it does not fit in a
    ///      `uint64`. Non-minimal encodings are accepted, matching the reference protobuf
    ///      implementations. On return `newOffset <= data.length` always holds, which is
    ///      what lets the callers below bound-check with an underflow-free subtraction.
    function decodeVarint(bytes memory data, uint256 offset) internal pure returns (uint64 value, uint256 newOffset) {
        uint256 end = data.length;
        // `shift` is uint64 so the shift below has matching operand types: solc warns
        // (3149) when a uint64 is shifted by a uint256. It reaches at most 63 — the loop
        // returns or reverts on the byte at that shift — so the `+= 7` cannot overflow.
        uint64 shift = 0;
        uint256 pos = offset;
        // An `offset` at or past the end simply skips the loop and falls through to the
        // truncation revert below, so it needs no separate check.
        while (pos < end) {
            uint8 b = uint8(data[pos]);
            // A 64-bit varint is at most 10 bytes (9 * 7 + 1 bits). On the tenth byte only
            // bit 63 is left, so anything above 0x01 — including the continuation bit,
            // which would imply an eleventh byte — cannot be represented.
            if (shift == 63 && b > 0x01) revert VarintOverflow();
            value |= uint64(b & 0x7F) << shift;
            // `pos` is bounded by `data.length` and `shift` by 63 (the branch above exits
            // on the byte that reaches it), so neither increment can wrap.
            unchecked {
                pos++;
                if (b & 0x80 == 0) return (value, pos);
                shift += 7;
            }
        }
        // Ran out of bytes with the continuation bit still set.
        revert TruncatedInput();
    }

    /// @notice Encode a protobuf field key (field_number << 3 | wire_type).
    function encodeFieldKey(uint64 fieldNumber, uint8 wireType) internal pure returns (bytes memory) {
        return encodeVarint((fieldNumber << 3) | uint64(wireType));
    }

    /// @notice Decode a protobuf field key.
    /// @dev Inherits the bounds and overflow checks of {decodeVarint}: a key that runs off
    ///      the end of `data` reverts rather than reporting field 0 / wire type 0.
    function decodeFieldKey(bytes memory data, uint256 offset)
        internal
        pure
        returns (uint64 fieldNumber, uint8 wireType, uint256 newOffset)
    {
        uint64 key;
        (key, newOffset) = decodeVarint(data, offset);
        // casting to 'uint8' is safe because `key & 0x07` is in [0, 7].
        // forge-lint: disable-next-line(unsafe-typecast)
        wireType = uint8(key & 0x07);
        fieldNumber = key >> 3;
    }

    /// @notice Encode bytes as a length-delimited protobuf field (length varint + raw bytes).
    function encodeLengthDelimited(bytes memory payload) internal pure returns (bytes memory) {
        bytes memory lengthBytes = encodeVarint(uint64(payload.length));
        return abi.encodePacked(lengthBytes, payload);
    }

    /// @notice Decode a length-delimited protobuf field at the given offset.
    /// @dev Reverts `TruncatedInput` when the declared length runs past the end of `data`.
    ///      Without the check the assembly copy below would splice adjacent memory into the
    ///      returned payload (zero-padded, so it looks like a well-formed short field), and
    ///      `newOffset` would jump past the end of the buffer, silently ending the caller's
    ///      decode loop with the remaining fields dropped.
    function decodeLengthDelimited(bytes memory data, uint256 offset)
        internal
        pure
        returns (bytes memory payload, uint256 newOffset)
    {
        uint64 length;
        (length, newOffset) = decodeVarint(data, offset);
        // `decodeVarint` bounds `newOffset` by `data.length`, so this subtraction cannot
        // underflow; `length` is a uint64 that the guard then bounds by the bytes actually
        // remaining, so the `newOffset += length` below cannot overflow either. Both are
        // `unchecked` because this helper is inlined at every length-delimited read, and
        // the redundant panic guards are pure bytecode.
        unchecked {
            if (length > data.length - newOffset) revert TruncatedInput();
        }

        payload = new bytes(length);
        uint256 src = newOffset;
        uint256 len = length;
        assembly ("memory-safe") {
            let dst := add(payload, 32)
            let srcPtr := add(add(data, 32), src)
            let end := add(dst, len)
            for {} lt(dst, end) {
                dst := add(dst, 32)
                srcPtr := add(srcPtr, 32)
            } { mstore(dst, mload(srcPtr)) }
        }
        unchecked {
            newOffset += length;
        }
    }

    /// @notice Encode a complete protobuf field: key + varint value.
    function encodeVarintField(uint64 fieldNumber, uint64 value) internal pure returns (bytes memory) {
        if (value == 0) return ""; // protobuf3 default, omit
        return abi.encodePacked(encodeFieldKey(fieldNumber, 0), encodeVarint(value));
    }

    /// @notice Encode a complete protobuf field: key + length-delimited value.
    function encodeBytesField(uint64 fieldNumber, bytes memory value) internal pure returns (bytes memory) {
        if (value.length == 0) return ""; // protobuf3 default, omit
        return abi.encodePacked(encodeFieldKey(fieldNumber, 2), encodeLengthDelimited(value));
    }

    /// @notice Skip a field value based on wire type. Returns the new offset.
    /// @dev Bounds-checked like the decoders: a truncated varint or a length prefix past the
    ///      end of `data` reverts rather than returning an offset beyond the buffer, which
    ///      the caller's `while (pos < data.length)` loop would read as a clean end of input.
    function skipField(bytes memory data, uint256 offset, uint8 wireType) internal pure returns (uint256) {
        if (wireType == 0) {
            (, offset) = decodeVarint(data, offset);
            return offset;
        } else if (wireType == 2) {
            uint64 length;
            (length, offset) = decodeVarint(data, offset);
            // Same reasoning as {decodeLengthDelimited}: `decodeVarint` bounds `offset` by
            // `data.length`, and the guard bounds `length` by what is left, so neither the
            // subtraction nor the addition can wrap.
            unchecked {
                if (length > data.length - offset) revert TruncatedInput();
                return offset + length;
            }
        } else {
            revert("Unsupported wire type");
        }
    }
}
