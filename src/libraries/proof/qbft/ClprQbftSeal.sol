// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";
import {Memory} from "@openzeppelin/contracts/utils/Memory.sol";

/// @title ClprQbftSeal
/// @notice Verifies that a Besu QBFT block header's committed-seals list contains at
///         least MIN_COMMITTED_SEALS entries and that the expected validator signed at
///         least one of them.  Reconstructs the sealing-header digest (same header with
///         `committedSeals = []` in extraData) and recovers each seal via `ecrecover`.
library ClprQbftSeal {
    error InvalidExtraData();
    error WrongSealCount(uint256 got);
    error SealLengthMismatch(uint256 got);
    error SealRecoverFailed();
    error ValidatorSealNotFound(address expected);

    /// @dev Index of the `extraData` field within an Ethereum block header. QBFT carries
    ///      its consensus metadata here.
    uint8 internal constant HEADER_EXTRA_DATA_INDEX = 12;

    // QBFT extraData layout: [vanity, validators[], vote, round, committedSeals[]]
    uint8 private constant EXTRA_FIELDS = 5;
    uint8 private constant EXTRA_INDEX_COMMITTED_SEALS = 4;
    uint8 private constant SEAL_LENGTH = 65;

    /// @dev Verify that `header[12]` (extraData) contains at least minCommittedSeals
    ///      committed seals and that `expectedValidator` signed at least one of them.
    ///      Reverts on any structural mismatch, recovery failure, or missing validator.
    function verify(uint8 minCommittedSeals, Memory.Slice[] memory header, address expectedValidator) internal pure {
        bytes memory extraDataInner = RLP.readBytes(header[HEADER_EXTRA_DATA_INDEX]);
        Memory.Slice[] memory extra = RLP.decodeList(extraDataInner);
        if (extra.length != EXTRA_FIELDS) revert InvalidExtraData();

        Memory.Slice[] memory seals = RLP.readList(extra[EXTRA_INDEX_COMMITTED_SEALS]);
        if (seals.length < minCommittedSeals) revert WrongSealCount(seals.length);

        bytes32 sealHash = _sealingDigest(header, extra);

        bool found = false;
        for (uint256 i = 0; i < seals.length;) {
            bytes memory seal = RLP.readBytes(seals[i]);
            if (seal.length != SEAL_LENGTH) revert SealLengthMismatch(seal.length);

            // QBFT seals carry v ∈ {0,1}; precompile expects {27,28}. Normalize.
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(seal, 0x20))
                s := mload(add(seal, 0x40))
                v := byte(0, mload(add(seal, 0x60)))
            }
            if (v < 27) v += 27;
            address recovered = ecrecover(sealHash, v, r, s);
            if (recovered == address(0)) revert SealRecoverFailed();
            if (recovered == expectedValidator) {
                found = true;
                break;
            }
            unchecked {
                i++;
            }
        }
        if (!found) revert ValidatorSealNotFound(expectedValidator);
    }

    /// @dev Reconstruct `keccak256(RLP(header_with_empty_seals))` — the digest the
    ///      validator originally signed before its seal was appended.
    function _sealingDigest(Memory.Slice[] memory header, Memory.Slice[] memory extra) private pure returns (bytes32) {
        bytes[] memory sealingExtraItems = new bytes[](EXTRA_FIELDS);
        for (uint256 i = 0; i < uint256(EXTRA_INDEX_COMMITTED_SEALS);) {
            sealingExtraItems[i] = Memory.toBytes(extra[i]);
            unchecked {
                ++i;
            }
        }
        sealingExtraItems[EXTRA_INDEX_COMMITTED_SEALS] = RLP.encode(new bytes[](0));
        bytes memory sealingExtraData = RLP.encode(sealingExtraItems);

        bytes[] memory sealingHeaderItems = new bytes[](header.length);
        for (uint256 i = 0; i < header.length;) {
            sealingHeaderItems[i] =
                (i == uint256(HEADER_EXTRA_DATA_INDEX)) ? RLP.encode(sealingExtraData) : Memory.toBytes(header[i]);
            unchecked {
                ++i;
            }
        }
        return keccak256(RLP.encode(sealingHeaderItems));
    }
}
