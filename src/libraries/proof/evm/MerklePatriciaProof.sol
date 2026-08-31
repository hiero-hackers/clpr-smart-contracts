// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";
import {Memory} from "@openzeppelin/contracts/utils/Memory.sol";

/// @title MerklePatriciaProof
/// @notice Minimal Ethereum Merkle-Patricia-Trie inclusion-proof verifier.
/// @dev Supports branch (17-item), extension and leaf (2-item) nodes referenced by 32-byte
///      keccak256 hashes. Inline (sub-32-byte) child references are intentionally rejected
///      — the worked-against tries (state, storage) always hash-reference at this size class.
///      Trie keys are 32-byte hashes; callers pre-hash so this lib stays generic.
library MerklePatriciaProof {
    error MPTEmptyProof();
    error MPTInvalidHashRef();
    error MPTInvalidNode();
    error MPTInlineNodeUnsupported();
    error MPTKeyMismatch();
    error MPTKeyAbsent();
    error MPTProofEndedEarly();
    error MPTInvalidPathPrefix();

    /// @notice Walks `proof` from `root` along nibbles of `keyHash`, returning the
    ///         RLP-decoded leaf value. Reverts on any structural mismatch or if the
    ///         key is proven absent.
    function verifyInclusion(bytes32 root, bytes32 keyHash, bytes[] memory proof)
        internal
        pure
        returns (bytes memory value)
    {
        if (proof.length == 0) revert MPTEmptyProof();

        bytes32 expectedHash = root;
        uint256 keyIdx = 0; // nibble cursor into keyHash (0..64)

        for (uint256 i = 0; i < proof.length; i++) {
            bytes memory node = proof[i];
            if (keccak256(node) != expectedHash) revert MPTInvalidHashRef();

            Memory.Slice[] memory items = RLP.decodeList(node);

            if (items.length == 17) {
                if (keyIdx >= 64) {
                    // Full key consumed — return the RLP-encoded value at the branch terminal.
                    return Memory.toBytes(items[16]);
                }
                uint8 nib = _nibAt(keyHash, keyIdx);
                keyIdx++;
                bytes memory child = RLP.readBytes(items[nib]);
                if (child.length == 0) revert MPTKeyAbsent();
                if (child.length != 32) revert MPTInlineNodeUnsupported();
                // casting to 'bytes32' is safe because child.length == 32 was checked above.
                // forge-lint: disable-next-line(unsafe-typecast)
                expectedHash = bytes32(child);
            } else if (items.length == 2) {
                bytes memory path = RLP.readBytes(items[0]);
                (bool isLeaf, uint256 pathLen, uint256 pathOffsetNibbles) = _decodePathPrefix(path);

                // Match path nibbles against keyHash[keyIdx..keyIdx+pathLen].
                if (pathLen + keyIdx > 64) revert MPTKeyMismatch();
                for (uint256 j = 0; j < pathLen; j++) {
                    uint8 pathNib = _pathNibAt(path, pathOffsetNibbles + j);
                    if (pathNib != _nibAt(keyHash, keyIdx + j)) revert MPTKeyMismatch();
                }
                keyIdx += pathLen;

                if (isLeaf) {
                    if (keyIdx != 64) revert MPTKeyMismatch();
                    // Return the RLP-encoded value verbatim (callers re-decode as needed).
                    return Memory.toBytes(items[1]);
                } else {
                    bytes memory child = RLP.readBytes(items[1]);
                    if (child.length != 32) revert MPTInlineNodeUnsupported();
                    // casting to 'bytes32' is safe because child.length == 32 was checked above.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    expectedHash = bytes32(child);
                }
            } else {
                revert MPTInvalidNode();
            }
        }
        revert MPTProofEndedEarly();
    }

    /// @notice Inclusion-proof variant that returns empty bytes when the key is proven absent
    ///         instead of reverting. Used for storage proofs where "absent slot" must be
    ///         interpreted as the zero value.
    function getOrEmpty(bytes32 root, bytes32 keyHash, bytes[] memory proof)
        internal
        pure
        returns (bytes memory value)
    {
        if (proof.length == 0) revert MPTEmptyProof();

        bytes32 expectedHash = root;
        uint256 keyIdx = 0;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes memory node = proof[i];
            if (keccak256(node) != expectedHash) revert MPTInvalidHashRef();

            Memory.Slice[] memory items = RLP.decodeList(node);

            if (items.length == 17) {
                if (keyIdx >= 64) {
                    return Memory.toBytes(items[16]);
                }
                uint8 nib = _nibAt(keyHash, keyIdx);
                keyIdx++;
                bytes memory child = RLP.readBytes(items[nib]);
                if (child.length == 0) return new bytes(0);
                if (child.length != 32) revert MPTInlineNodeUnsupported();
                // casting to 'bytes32' is safe because child.length == 32 was checked above.
                // forge-lint: disable-next-line(unsafe-typecast)
                expectedHash = bytes32(child);
            } else if (items.length == 2) {
                bytes memory path = RLP.readBytes(items[0]);
                (bool isLeaf, uint256 pathLen, uint256 pathOffsetNibbles) = _decodePathPrefix(path);

                if (pathLen + keyIdx > 64) return new bytes(0);
                for (uint256 j = 0; j < pathLen; j++) {
                    uint8 pathNib = _pathNibAt(path, pathOffsetNibbles + j);
                    if (pathNib != _nibAt(keyHash, keyIdx + j)) {
                        // Path diverges — key is absent under this subtree.
                        return new bytes(0);
                    }
                }
                keyIdx += pathLen;

                if (isLeaf) {
                    if (keyIdx != 64) return new bytes(0);
                    return Memory.toBytes(items[1]);
                } else {
                    bytes memory child = RLP.readBytes(items[1]);
                    if (child.length != 32) revert MPTInlineNodeUnsupported();
                    // casting to 'bytes32' is safe because child.length == 32 was checked above.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    expectedHash = bytes32(child);
                }
            } else {
                revert MPTInvalidNode();
            }
        }
        revert MPTProofEndedEarly();
    }

    // ── internal helpers ───────────────────────────────────────────────────────

    /// @dev Returns the nibble at position `i` within a 32-byte hash (0..63).
    function _nibAt(bytes32 keyHash, uint256 i) private pure returns (uint8) {
        uint8 b = uint8(keyHash[i >> 1]);
        return (i & 1 == 0) ? (b >> 4) : (b & 0x0f);
    }

    /// @dev Returns the nibble at position `i` within an MPT compact-encoded path's *payload*.
    ///      Position 0 here is the first nibble AFTER the prefix-nibble metadata.
    function _pathNibAt(bytes memory path, uint256 i) private pure returns (uint8) {
        uint8 b = uint8(path[i >> 1]);
        return (i & 1 == 0) ? (b >> 4) : (b & 0x0f);
    }

    /// @dev Decode an MPT compact-encoded path prefix.
    /// @return isLeaf True for leaf nodes (prefix nibble bit-1 set), false for extension.
    /// @return pathLen Number of meaningful nibbles in the path payload.
    /// @return payloadOffsetNibbles Nibble index at which the meaningful path nibbles start
    ///         within `path` (1 for odd-length, 2 for even-length to skip a padding nibble).
    function _decodePathPrefix(bytes memory path)
        private
        pure
        returns (bool isLeaf, uint256 pathLen, uint256 payloadOffsetNibbles)
    {
        if (path.length == 0) revert MPTInvalidPathPrefix();
        uint8 firstByte = uint8(path[0]);
        uint8 prefixNib = firstByte >> 4;
        // prefix nibble: 0x0 ext-even, 0x1 ext-odd, 0x2 leaf-even, 0x3 leaf-odd
        if (prefixNib > 3) revert MPTInvalidPathPrefix();
        isLeaf = (prefixNib & 0x2) != 0;
        bool isOdd = (prefixNib & 0x1) != 0;
        uint256 totalNibbles = path.length * 2;
        if (isOdd) {
            // First nibble of payload lives in the low half of byte 0.
            pathLen = totalNibbles - 1;
            payloadOffsetNibbles = 1;
        } else {
            // Low half of byte 0 is a padding 0x0; payload starts at byte 1.
            // For even-length paths the low half MUST be zero per spec — enforce it.
            if (firstByte & 0x0f != 0) revert MPTInvalidPathPrefix();
            pathLen = totalNibbles - 2;
            payloadOffsetNibbles = 2;
        }
    }
}
