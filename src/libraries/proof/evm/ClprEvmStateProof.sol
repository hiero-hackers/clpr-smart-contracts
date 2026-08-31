// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {MerklePatriciaProof} from "@hiero-ledger/clpr/libraries/proof/evm/MerklePatriciaProof.sol";
import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";
import {Memory} from "@openzeppelin/contracts/utils/Memory.sol";

/// @title ClprEvmStateProof
/// @notice Helpers for verifying Ethereum-style account + fixed-storage-slot Merkle-Patricia
///         inclusion proofs against a `stateRoot`, and decoding the resulting account leaf
///         into `(storageRoot, codeHash)`
library ClprEvmStateProof {
    error InvalidAccount();
    error InvalidStorageEntry();
    error SlotNotProven(bytes32 slot);

    /// @dev Walk the account proof from `stateRoot` to the leaf for `keccak256(account)`,
    ///      then strip the leaf's byte-string envelope so the caller gets the inner
    ///      4-item account RLP list (`[nonce, balance, storageRoot, codeHash]`).
    function verifyAccount(Memory.Slice accountProofItem, bytes32 stateRoot, address account)
        internal
        pure
        returns (bytes memory accountRlp)
    {
        bytes[] memory proof = _slicesToProofNodes(RLP.readList(accountProofItem));
        bytes32 keyHash = keccak256(abi.encodePacked(account));
        accountRlp = RLP.decodeBytes(MerklePatriciaProof.verifyInclusion(stateRoot, keyHash, proof));
    }

    /// @dev Decode the 4-item account RLP list to `(storageRoot, codeHash)`.
    function decodeAccount(bytes memory accountRlp) internal pure returns (bytes32 storageRoot, bytes32 codeHash) {
        Memory.Slice[] memory fields = RLP.decodeList(accountRlp);
        if (fields.length != 4) revert InvalidAccount();
        storageRoot = RLP.readBytes32(fields[2]);
        codeHash = RLP.readBytes32(fields[3]);
    }

    /// @dev Verify storage slots whose slot numbers are DERIVED BY THE CALLER (never taken from the
    ///      proof). For each `expectedSlots[j]`, find the entry whose declared slot equals it, verify
    ///      that entry's Merkle proof against `storageRoot` at trie path `keccak256(slot)`, and
    ///      return the proven value.
    /// @param entries Decoded storage-proof entries, each a 2-tuple `[slotNumber, proofNodes]`.
    ///                No value is carried: the proven value is read from the Merkle proof leaf,
    ///                so passing it alongside would be redundant (and unverified) data.
    function verifyProvenSlots(Memory.Slice[] memory entries, bytes32 storageRoot, bytes32[] memory expectedSlots)
        internal
        pure
        returns (bytes32[] memory provenValues)
    {
        provenValues = new bytes32[](expectedSlots.length);
        for (uint256 j = 0; j < expectedSlots.length;) {
            bool found = false;
            for (uint256 i = 0; i < entries.length;) {
                Memory.Slice[] memory entryFields = RLP.readList(entries[i]);
                if (entryFields.length != 2) revert InvalidStorageEntry();
                if (RLP.readBytes32(entryFields[0]) != expectedSlots[j]) {
                    unchecked {
                        i++;
                    }
                    continue;
                }

                bytes[] memory proofNodes = _slicesToProofNodes(RLP.readList(entryFields[1]));
                provenValues[j] = _decodeStorageScalar(
                    MerklePatriciaProof.getOrEmpty(
                        storageRoot, keccak256(abi.encodePacked(expectedSlots[j])), proofNodes
                    )
                );
                found = true;
                break;
            }
            if (!found) revert SlotNotProven(expectedSlots[j]);
            unchecked {
                j++;
            }
        }
    }

    /// @dev Storage-trie leaf values are double-wrapped: outer byte-string envelope around
    ///      the RLP-encoded uint256 scalar (leading-zero-stripped). Strip both layers.
    ///      Empty / absent ⇒ zero.
    function _decodeStorageScalar(bytes memory rlpValue) private pure returns (bytes32) {
        if (rlpValue.length == 0) return bytes32(0);
        bytes memory inner = RLP.decodeBytes(rlpValue);
        if (inner.length == 0) return bytes32(0);
        return bytes32(RLP.decodeUint256(inner));
    }

    function _slicesToProofNodes(Memory.Slice[] memory slices) private pure returns (bytes[] memory out) {
        out = new bytes[](slices.length);
        for (uint256 i = 0; i < slices.length;) {
            // Each child of a proof list is RLP-encoded as a byte string whose payload is
            // the trie node's own RLP encoding. Unwrap the string envelope.
            out[i] = RLP.readBytes(slices[i]);
            unchecked {
                i++;
            }
        }
    }
}
