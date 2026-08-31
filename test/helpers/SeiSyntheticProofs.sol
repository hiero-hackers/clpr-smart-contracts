// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SeiCometBftVerifier} from "@hiero-ledger/clpr/verifiers/evm/sei/SeiCometBftVerifier.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobufHelpers as PB} from "@hiero-ledger/clpr/libraries/codec/ClprProtobufHelpers.sol";
import {CometBftLib} from "@hiero-ledger/clpr/libraries/proof/cometbft/CometBftLib.sol";
import {Ics23Lib} from "@hiero-ledger/clpr/libraries/proof/cometbft/Ics23Lib.sol";

/// @dev Shared IAVL/ICS-23 proof-building utilities for Sei verifier tests, mirroring the
///      QbftSyntheticProofs pattern: produces fully valid multi-leaf existence proofs without
///      external fixtures, so Sei test contracts don't each hand-roll their own copy.
abstract contract SeiSyntheticProofs is Test {
    /// @dev sha256 leaf hash for an ICS-23 IAVL existence proof: `sha256(0x00 || varint(len(key)) ||
    ///      key || varint(len(sha256(value))) || sha256(value))`.
    function _leafHash(bytes memory key, bytes memory value) internal pure returns (bytes32) {
        bytes memory hashedValue = abi.encodePacked(sha256(value));
        bytes memory encodedKey = abi.encodePacked(PB.encodeVarint(uint64(key.length)), key);
        bytes memory encodedValue = abi.encodePacked(PB.encodeVarint(uint64(hashedValue.length)), hashedValue);
        return sha256(abi.encodePacked(bytes1(0x00), encodedKey, encodedValue));
    }

    /// @dev Encodes a full `SeiStorageProofEntry{key, value, iavl_proof}` whose Ics23Lib.ExistenceProof
    ///      carries a real `path` of InnerOps.
    function _encodeExistenceEntryWithPath(bytes memory key, bytes memory value, Ics23Lib.InnerOp[] memory path)
        internal
        pure
        returns (bytes memory entry)
    {
        bytes memory leafBytes = abi.encodePacked(
            PB.encodeVarintField(1, uint8(1)), // hashOp = SHA256
            PB.encodeVarintField(2, uint8(0)), // prehashKey = NO_HASH
            PB.encodeVarintField(3, uint8(1)), // prehashValue = SHA256
            PB.encodeVarintField(4, uint8(1)), // lengthOp = VAR_PROTO
            PB.encodeBytesField(5, hex"00") // leaf prefix
        );
        bytes memory epInner = abi.encodePacked(
            PB.encodeBytesField(1, key), PB.encodeBytesField(2, value), PB.encodeBytesField(3, leafBytes)
        );
        for (uint256 i = 0; i < path.length; i++) {
            bytes memory innerOpBytes = abi.encodePacked(
                PB.encodeVarintField(1, path[i].hashOp),
                PB.encodeBytesField(2, path[i].prefix),
                PB.encodeBytesField(3, path[i].suffix)
            );
            epInner = abi.encodePacked(epInner, PB.encodeBytesField(4, innerOpBytes));
        }
        bytes memory iavlProofBytes = PB.encodeBytesField(1, epInner);
        entry = abi.encodePacked(
            PB.encodeBytesField(1, key), PB.encodeBytesField(2, value), PB.encodeBytesField(3, iavlProofBytes)
        );
    }

    /// @dev Chains N existence leaves (leaf0 combines with leaf1 -> n1, n1 with leaf2 -> n2, ...)
    ///      into one shared IAVL root, each leaf's own `path` independently reconstructing the
    ///      same root (including N=1, the degenerate "leaf hash IS the root" case).
    function _buildLinearChainStorageProof(bytes[] memory keys, bytes32[] memory values)
        internal
        pure
        returns (bytes[] memory entries, bytes32 root)
    {
        uint256 n = keys.length;
        bytes32[] memory leaf = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaf[i] = _leafHash(keys[i], abi.encodePacked(values[i]));
        }

        entries = new bytes[](n);
        if (n == 1) {
            entries[0] = _encodeExistenceEntryWithPath(keys[0], abi.encodePacked(values[0]), new Ics23Lib.InnerOp[](0));
            root = leaf[0];
            return (entries, root);
        }

        bytes[] memory prefixes = new bytes[](n - 1);
        bytes[] memory suffixes = new bytes[](n - 1);
        bytes32[] memory nodes = new bytes32[](n);
        nodes[0] = leaf[0];
        for (uint256 k = 0; k < n - 1; k++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            prefixes[k] = abi.encodePacked(bytes1(0x11), bytes1(0x00), bytes1(0x00), bytes1(uint8(k)));
            // forge-lint: disable-next-line(unsafe-typecast)
            suffixes[k] = abi.encodePacked(bytes1(uint8(k + 1)), leaf[k + 1]);
            nodes[k + 1] = sha256(abi.encodePacked(prefixes[k], nodes[k], suffixes[k]));
        }
        root = nodes[n - 1];

        {
            Ics23Lib.InnerOp[] memory path0 = new Ics23Lib.InnerOp[](n - 1);
            for (uint256 k = 0; k < n - 1; k++) {
                path0[k] = Ics23Lib.InnerOp({hashOp: 1, prefix: prefixes[k], suffix: suffixes[k]});
            }
            entries[0] = _encodeExistenceEntryWithPath(keys[0], abi.encodePacked(values[0]), path0);
        }
        for (uint256 i = 1; i < n; i++) {
            Ics23Lib.InnerOp[] memory pathI = new Ics23Lib.InnerOp[](n - i);
            pathI[0] = Ics23Lib.InnerOp({
                hashOp: 1,
                // forge-lint: disable-next-line(unsafe-typecast)
                prefix: abi.encodePacked(prefixes[i - 1], nodes[i - 1], bytes1(uint8(i))),
                suffix: ""
            });
            for (uint256 k = i; k < n - 1; k++) {
                pathI[k - i + 1] = Ics23Lib.InnerOp({hashOp: 1, prefix: prefixes[k], suffix: suffixes[k]});
            }
            entries[i] = _encodeExistenceEntryWithPath(keys[i], abi.encodePacked(values[i]), pathI);
        }
    }

    /// @dev Fixed-5-leaf convenience wrapper over {_buildLinearChainStorageProof} for callers that
    ///      already have full 53-byte IAVL keys (e.g. to deliberately corrupt one position).
    function _buildFiveLeafStorageProof(bytes[5] memory keys, bytes32[5] memory values)
        internal
        pure
        returns (bytes[5] memory entries, bytes32 iavlRoot)
    {
        bytes[] memory keysDyn = new bytes[](5);
        bytes32[] memory valuesDyn = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            keysDyn[i] = keys[i];
            valuesDyn[i] = values[i];
        }
        (bytes[] memory entriesDyn, bytes32 root) = _buildLinearChainStorageProof(keysDyn, valuesDyn);
        for (uint256 i = 0; i < 5; i++) {
            entries[i] = entriesDyn[i];
        }
        iavlRoot = root;
    }

    /// @dev Builds five genuinely distinct, correctly-keyed IAVL existence proofs — one per real
    ///      `Channel` metadata slot (`cBase+1/+2/+4/+5/+16`, the last being
    ///      `endpointManifestVersion`) — via {_buildFiveLeafStorageProof}.
    function _buildFiveLeafChannelProof(bytes32 channelId, bytes20 serviceAddr20, bytes32[5] memory values)
        internal
        pure
        returns (bytes[5] memory entries, bytes32 iavlRoot)
    {
        // `15` mirrors ClprEvmBundleVerifier.CHANNELS_BASE_SLOT (the `_channels` mapping's
        // base storage slot per storage-layout.json).
        bytes32 cBase = keccak256(abi.encode(channelId, uint256(15)));
        uint8[5] memory offsets = [1, 2, 4, 5, 16];

        bytes[5] memory keys;
        for (uint256 i = 0; i < 5; i++) {
            keys[i] = abi.encodePacked(uint8(0x03), serviceAddr20, bytes32(uint256(cBase) + offsets[i]));
        }
        (entries, iavlRoot) = _buildFiveLeafStorageProof(keys, values);
    }

    function _syntheticHeader() internal pure virtual returns (CometBftLib.SeiHeader memory h) {
        h.versionBlock = 11;
        h.versionApp = 1;
        h.chainId = "sei-chain-1";
        h.height = 100;
        h.timeSeconds = 1_700_000_000;
        h.timeNanos = 0;
        h.lastBlockIdHash = bytes32(uint256(0xAAAA));
        h.lastBlockIdPartSetTotal = 1;
        h.lastBlockIdPartSetHash = bytes32(uint256(0xBBBB));
        h.lastCommitHash = bytes32(uint256(0x01));
        h.dataHash = bytes32(uint256(0x02));
        h.validatorsHash = bytes32(uint256(0x03));
        h.nextValidatorsHash = bytes32(uint256(0x04));
        h.consensusHash = bytes32(uint256(0x05));
        h.appHash = bytes32(uint256(0x06));
        h.lastResultsHash = bytes32(uint256(0x07));
        h.evidenceHash = bytes32(uint256(0x08));
        h.proposerAddress = bytes20(address(0xDEAD));
    }

    function _buildThrottlesBytes(ClprTypes.Throttles memory throttles) internal pure virtual returns (bytes memory) {
        return abi.encodePacked(
            PB.encodeVarintField(1, uint64(throttles.maxMessagesPerBundle)),
            PB.encodeVarintField(2, uint64(throttles.maxMessagePayloadBytes)),
            PB.encodeVarintField(3, uint64(throttles.maxGasPerMessage)),
            PB.encodeVarintField(4, uint64(throttles.maxQueueDepth)),
            PB.encodeVarintField(5, uint64(throttles.maxSyncBytes))
        );
    }

    function _buildHeaderBytes(CometBftLib.SeiHeader memory header) internal pure virtual returns (bytes memory) {
        bytes memory timeBytes = abi.encodePacked(
            PB.encodeVarintField(1, uint64(header.timeSeconds)),
            PB.encodeVarintField(2, uint64(uint32(header.timeNanos)))
        );
        bytes memory lastBlockIdBytes = abi.encodePacked(
            PB.encodeBytesField(1, abi.encodePacked(header.lastBlockIdHash)),
            PB.encodeVarintField(2, uint64(header.lastBlockIdPartSetTotal)),
            PB.encodeBytesField(3, abi.encodePacked(header.lastBlockIdPartSetHash))
        );
        return abi.encodePacked(
            PB.encodeVarintField(1, header.versionBlock),
            PB.encodeVarintField(2, header.versionApp),
            PB.encodeBytesField(3, bytes(header.chainId)),
            PB.encodeVarintField(4, uint64(header.height)),
            PB.encodeBytesField(5, timeBytes),
            PB.encodeBytesField(6, lastBlockIdBytes),
            PB.encodeBytesField(7, abi.encodePacked(header.lastCommitHash)),
            PB.encodeBytesField(8, abi.encodePacked(header.dataHash)),
            PB.encodeBytesField(9, abi.encodePacked(header.validatorsHash)),
            PB.encodeBytesField(10, abi.encodePacked(header.nextValidatorsHash)),
            PB.encodeBytesField(11, abi.encodePacked(header.consensusHash)),
            PB.encodeBytesField(12, abi.encodePacked(header.appHash)),
            PB.encodeBytesField(13, abi.encodePacked(header.lastResultsHash)),
            PB.encodeBytesField(14, abi.encodePacked(header.evidenceHash)),
            PB.encodeBytesField(15, abi.encodePacked(header.proposerAddress))
        );
    }

    function _buildCommitBytes(CometBftLib.SeiCommit memory commit, int64 timeSeconds)
        internal
        pure
        virtual
        returns (bytes memory)
    {
        bytes memory timeBytes =
        // forge-lint: disable-next-line(unsafe-typecast)
        abi.encodePacked(PB.encodeVarintField(1, uint64(timeSeconds)), PB.encodeVarintField(2, 0));
        bytes memory sig0Bytes =
            abi.encodePacked(PB.encodeBytesField(1, timeBytes), PB.encodeBytesField(2, commit.signatures[0].signature));
        bytes memory sig1Bytes =
            abi.encodePacked(PB.encodeBytesField(1, timeBytes), PB.encodeBytesField(2, commit.signatures[1].signature));
        return abi.encodePacked(
            PB.encodeVarintField(1, uint64(uint32(commit.round))),
            PB.encodeVarintField(2, uint64(commit.partSetTotal)),
            PB.encodeBytesField(3, abi.encodePacked(commit.partSetHash)),
            PB.encodeBytesField(4, commit.signersBits),
            PB.encodeBytesField(5, sig0Bytes),
            PB.encodeBytesField(5, sig1Bytes)
        );
    }

    function _buildStorageProofEntry(bytes memory spKey, bytes memory spValue)
        internal
        pure
        virtual
        returns (bytes memory entry, bytes32 iavlRoot)
    {
        Ics23Lib.LeafOp memory leaf =
            Ics23Lib.LeafOp({hashOp: 1, prehashKey: 0, prehashValue: 1, lengthOp: 1, prefix: hex"00"});

        bytes memory hashedValue = abi.encodePacked(sha256(spValue));
        bytes memory encodedKey = abi.encodePacked(PB.encodeVarint(uint64(spKey.length)), spKey);
        bytes memory encodedValue = abi.encodePacked(PB.encodeVarint(uint64(hashedValue.length)), hashedValue);
        iavlRoot = sha256(abi.encodePacked(leaf.prefix, encodedKey, encodedValue));

        bytes memory leafBytes = abi.encodePacked(
            PB.encodeVarintField(1, leaf.hashOp),
            PB.encodeVarintField(2, leaf.prehashKey),
            PB.encodeVarintField(3, leaf.prehashValue),
            PB.encodeVarintField(4, leaf.lengthOp),
            PB.encodeBytesField(5, leaf.prefix)
        );
        bytes memory epInner = abi.encodePacked(
            PB.encodeBytesField(1, spKey), PB.encodeBytesField(2, spValue), PB.encodeBytesField(3, leafBytes)
        );
        bytes memory iavlProofBytes = PB.encodeBytesField(1, epInner);

        entry = abi.encodePacked(
            PB.encodeBytesField(1, spKey), PB.encodeBytesField(2, spValue), PB.encodeBytesField(3, iavlProofBytes)
        );
    }

    function _buildMultistoreProof(bytes32 iavlRoot)
        internal
        pure
        virtual
        returns (bytes memory multistoreProofBytes, bytes32 appHash)
    {
        bytes memory storeKey = bytes("evm");
        bytes memory storeRootBytes = abi.encodePacked(iavlRoot);

        bytes memory tmHashedValue = abi.encodePacked(sha256(storeRootBytes));
        bytes memory tmEncodedKey = abi.encodePacked(PB.encodeVarint(uint64(storeKey.length)), storeKey);
        bytes memory tmEncodedValue = abi.encodePacked(PB.encodeVarint(uint64(tmHashedValue.length)), tmHashedValue);
        appHash = sha256(abi.encodePacked(hex"00", tmEncodedKey, tmEncodedValue));

        Ics23Lib.LeafOp memory leaf =
            Ics23Lib.LeafOp({hashOp: 1, prehashKey: 0, prehashValue: 1, lengthOp: 1, prefix: hex"00"});

        bytes memory tmLeafBytes = abi.encodePacked(
            PB.encodeVarintField(1, leaf.hashOp),
            PB.encodeVarintField(2, leaf.prehashKey),
            PB.encodeVarintField(3, leaf.prehashValue),
            PB.encodeVarintField(4, leaf.lengthOp),
            PB.encodeBytesField(5, leaf.prefix)
        );
        bytes memory tmEpInner = abi.encodePacked(
            PB.encodeBytesField(1, storeKey),
            PB.encodeBytesField(2, storeRootBytes),
            PB.encodeBytesField(3, tmLeafBytes)
        );
        multistoreProofBytes = PB.encodeBytesField(1, tmEpInner);
    }

    function _encodeValidatorSingleWrapped(CometBftLib.SeiValidator memory v)
        internal
        pure
        virtual
        returns (bytes memory)
    {
        bytes memory pubKeyField = PB.encodeBytesField(1, abi.encodePacked(v.ed25519PubKey));
        bytes memory vpField;
        if (v.votingPower != 0) {
            vpField = PB.encodeVarintField(2, uint64(v.votingPower));
        }
        return abi.encodePacked(pubKeyField, vpField);
    }
}
