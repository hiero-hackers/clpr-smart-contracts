// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title CometBftLib
/// @notice CometBFT block-hash computation, simple Merkle tree, and canonical-vote
///         protobuf encoding helpers. All functions are pure.
library CometBftLib {
    uint8 internal constant PRECOMMIT_TYPE = 2;

    error EmptyValidatorSet();

    // ── Structs ───────────────────────────────────────────────────────────────

    struct SeiValidator {
        bytes32 ed25519PubKey; // 32 bytes
        int64 votingPower;
    }

    /// @dev Parsed SeiHeader fields needed for verification.
    struct SeiHeader {
        uint64 versionBlock;
        uint64 versionApp;
        string chainId;
        int64 height;
        // time
        int64 timeSeconds;
        int32 timeNanos;
        // lastBlockId
        bytes32 lastBlockIdHash;
        uint32 lastBlockIdPartSetTotal;
        bytes32 lastBlockIdPartSetHash;
        // hashes
        bytes32 lastCommitHash;
        bytes32 dataHash;
        bytes32 validatorsHash;
        bytes32 nextValidatorsHash;
        bytes32 consensusHash;
        bytes32 appHash;
        bytes32 lastResultsHash;
        bytes32 evidenceHash;
        bytes20 proposerAddress;
    }

    struct CommitSig {
        int64 timestampSeconds;
        int32 timestampNanos;
        bytes signature; // 64-byte Ed25519 signature
    }

    /// @dev Parsed SeiCommit.
    struct SeiCommit {
        int64 height;
        int32 round;
        bytes32 blockIdHash;
        uint32 partSetTotal;
        bytes32 partSetHash;
        bytes signersBits;
        CommitSig[] signatures;
    }

    // ── Validator set hash ────────────────────────────────────────────────────

    /// @dev Computes the validator set hash: simple Merkle root over SimpleValidator leaves.
    ///      SimpleValidator = proto( field1=pubKey(field1=ed25519bytes), field2=votingPower )
    function validatorSetHash(SeiValidator[] memory validators) internal pure returns (bytes32) {
        if (validators.length == 0) revert EmptyValidatorSet();
        bytes[] memory leaves = new bytes[](validators.length);
        for (uint256 i = 0; i < validators.length; i++) {
            leaves[i] = encodeValidator(validators[i]);
        }
        return bytes32(simpleMerkleRoot(leaves));
    }

    /// @dev Encodes a SimpleValidator for Merkle hashing.
    ///      proto: field1 (LEN) { field1 (LEN) ed25519PubKey } field2 (VARINT) votingPower
    function encodeValidator(SeiValidator memory v) internal pure returns (bytes memory) {
        bytes memory pubKeyInner = pbBytesField(1, abi.encodePacked(v.ed25519PubKey));
        bytes memory pubKeyField = pbMessageField(1, pubKeyInner);
        bytes memory vpField = bytes("");
        if (v.votingPower != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            vpField = abi.encodePacked(pbTag(2, 0), pbVarint(uint64(int64(v.votingPower))));
        }
        return abi.encodePacked(pubKeyField, vpField);
    }

    // ── Header hash ──────────────────────────────────────────────────────────

    /// @dev Computes header hash: simple Merkle root over 14 cdc-encoded fields.
    function headerHash(SeiHeader memory h) internal pure returns (bytes32) {
        bytes[] memory fields = new bytes[](14);

        // 0: tmversion.Consensus{block, app}
        fields[0] = abi.encodePacked(pbVarintField(1, h.versionBlock), pbVarintField(2, h.versionApp));
        // 1: chain_id (string wrapped in gogo StringValue → field 1 bytes)
        fields[1] = pbBytesField(1, bytes(h.chainId));
        // 2: height (Int64Value → field 1 varint)
        fields[2] = pbVarintField(1, uint64(h.height));
        // 3: time (Timestamp: field1=seconds, field2=nanos)
        fields[3] = abi.encodePacked(
            h.timeSeconds != 0 ? abi.encodePacked(pbTag(1, 0), pbVarint(uint64(h.timeSeconds))) : bytes(""),
            h.timeNanos != 0 ? abi.encodePacked(pbTag(2, 0), pbVarint(uint32(h.timeNanos))) : bytes("")
        );
        // 4: last_block_id (BlockID)
        fields[4] = encodeBlockId(h.lastBlockIdHash, h.lastBlockIdPartSetTotal, h.lastBlockIdPartSetHash);
        // 5–13: hash fields (each BytesValue wrapper → field 1 bytes)
        fields[5] = pbBytesField(1, abi.encodePacked(h.lastCommitHash));
        fields[6] = pbBytesField(1, abi.encodePacked(h.dataHash));
        fields[7] = pbBytesField(1, abi.encodePacked(h.validatorsHash));
        fields[8] = pbBytesField(1, abi.encodePacked(h.nextValidatorsHash));
        fields[9] = pbBytesField(1, abi.encodePacked(h.consensusHash));
        fields[10] = pbBytesField(1, abi.encodePacked(h.appHash));
        fields[11] = pbBytesField(1, abi.encodePacked(h.lastResultsHash));
        fields[12] = pbBytesField(1, abi.encodePacked(h.evidenceHash));
        fields[13] = pbBytesField(1, abi.encodePacked(h.proposerAddress));

        return bytes32(simpleMerkleRoot(fields));
    }

    /// @dev Encodes BlockID for header hash computation.
    function encodeBlockId(bytes32 hash, uint32 partTotal, bytes32 partHash) internal pure returns (bytes memory) {
        bytes memory partSetHeader =
            abi.encodePacked(pbVarintField(1, partTotal), pbBytesField(2, abi.encodePacked(partHash)));
        return bytes.concat(pbBytesField(1, abi.encodePacked(hash)), pbMessageField(2, partSetHeader));
    }

    // ── Precommit sign bytes ──────────────────────────────────────────────────

    /// @dev Builds canonical precommit sign bytes using pre-computed prefix and suffix.
    function precommitSignBytesHoisted(bytes memory prefix, bytes memory suffix, int64 tsSeconds, int32 tsNanos)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory timestamp = abi.encodePacked(
            // forge-lint: disable-next-line(unsafe-typecast)
            tsSeconds != 0 ? abi.encodePacked(pbTag(1, 0), pbVarint(uint64(tsSeconds))) : bytes(""),
            // forge-lint: disable-next-line(unsafe-typecast)
            tsNanos != 0 ? abi.encodePacked(pbTag(2, 0), pbVarint(uint32(tsNanos))) : bytes("")
        );
        bytes memory vote = bytes.concat(prefix, pbMessageField(5, timestamp), suffix);
        // length-prefix (protoio.MarshalDelimited)
        return abi.encodePacked(pbVarint(vote.length), vote);
    }

    /// @dev Builds canonical precommit sign bytes.
    ///      CanonicalVote{type=PRECOMMIT(2), height(sfixed64), round(sfixed64),
    ///                    block_id, timestamp, chain_id}, length-prefixed.
    function precommitSignBytes(
        string memory chainId,
        int64 height,
        int32 round,
        bytes32 blockIdHash,
        uint32 partTotal,
        bytes32 partHash,
        int64 tsSeconds,
        int32 tsNanos
    ) internal pure returns (bytes memory) {
        bytes memory partSetHeader =
            abi.encodePacked(pbVarintField(1, partTotal), pbBytesField(2, abi.encodePacked(partHash)));
        bytes memory canonicalBlockId =
            bytes.concat(pbBytesField(1, abi.encodePacked(blockIdHash)), pbMessageField(2, partSetHeader));
        bytes memory prefix = abi.encodePacked(
            pbVarintField(1, PRECOMMIT_TYPE),
            height != 0 ? abi.encodePacked(pbTag(2, 1), sfixed64LE(height)) : bytes(""),
            round != 0 ? abi.encodePacked(pbTag(3, 1), sfixed64LE(round)) : bytes(""),
            pbMessageField(4, canonicalBlockId)
        );
        bytes memory suffix = pbBytesField(6, bytes(chainId));
        return precommitSignBytesHoisted(prefix, suffix, tsSeconds, tsNanos);
    }

    // ── Tendermint simple Merkle tree (RFC 6962 domain separation, SHA-256) ───

    /// @dev leafHash = sha256(0x00 || leaf), innerHash = sha256(0x01 || left || right).
    ///      Split at the largest power of two strictly less than the item count.
    function simpleMerkleRoot(bytes[] memory items) internal pure returns (bytes32) {
        if (items.length == 0) return sha256("");
        return subtreeRoot(items, 0, items.length);
    }

    function subtreeRoot(bytes[] memory items, uint256 from, uint256 count) internal pure returns (bytes32) {
        if (count == 1) {
            return sha256(abi.encodePacked(bytes1(0x00), items[from]));
        }
        uint256 split = splitPoint(count);
        bytes32 left = subtreeRoot(items, from, split);
        bytes32 right = subtreeRoot(items, from + split, count - split);
        return sha256(abi.encodePacked(bytes1(0x01), left, right));
    }

    /// @dev Largest power of two strictly less than n (n >= 2).
    function splitPoint(uint256 n) internal pure returns (uint256) {
        uint256 k = 1;
        while (k * 2 < n) k *= 2;
        return k;
    }

    // ── Protobuf wire format helpers (CometBFT canonical vote encoding) ───────

    function pbTag(uint64 field, uint8 wireType) internal pure returns (bytes memory) {
        return pbVarint((field << 3) | wireType);
    }

    function pbVarint(uint256 value) internal pure returns (bytes memory out) {
        // max 10 bytes
        bytes memory tmp = new bytes(10);
        uint256 idx;
        do {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(value & 0x7F);
            value >>= 7;
            if (value != 0) b |= 0x80;
            tmp[idx++] = bytes1(b);
        } while (value != 0);
        out = new bytes(idx);
        for (uint256 j; j < idx; j++) {
            out[j] = tmp[j];
        }
    }

    /// @dev Varint field (omitted when zero, proto3 default).
    function pbVarintField(uint64 field, uint256 value) internal pure returns (bytes memory) {
        if (value == 0) return "";
        return abi.encodePacked(pbTag(field, 0), pbVarint(value));
    }

    /// @dev Bytes/string field (omitted when empty, proto3 default).
    function pbBytesField(uint64 field, bytes memory value) internal pure returns (bytes memory) {
        if (value.length == 0) return "";
        return abi.encodePacked(pbTag(field, 2), pbVarint(value.length), value);
    }

    /// @dev Embedded message field — always written even when empty (gogoproto nullable=false).
    function pbMessageField(uint64 field, bytes memory msg_) internal pure returns (bytes memory) {
        return abi.encodePacked(pbTag(field, 2), pbVarint(msg_.length), msg_);
    }

    /// @dev sfixed64 little-endian (8 bytes).
    ///      NOTE: `bytes8(uint64)` packs big-endian (MSB first), so to emit little-endian we place
    ///      the least-significant byte in the leftmost (most-significant) position of the bytes8.
    function sfixed64LE(int64 value) internal pure returns (bytes8) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 u = uint64(value);
        // forge-lint: disable-start(unsafe-typecast)
        return bytes8(
            (uint64(uint8(u)) << 56) | (uint64(uint8(u >> 8)) << 48) | (uint64(uint8(u >> 16)) << 40)
                | (uint64(uint8(u >> 24)) << 32) | (uint64(uint8(u >> 32)) << 24) | (uint64(uint8(u >> 40)) << 16)
                | (uint64(uint8(u >> 48)) << 8) | (uint64(uint8(u >> 56)))
        );
        // forge-lint: disable-end(unsafe-typecast)
    }
}
