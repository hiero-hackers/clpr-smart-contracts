// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title ClprConfigHash
/// @notice Pure helpers that produce one-word digests of CLPR configuration values.
///         Peers and observers can recompute the same digest off-chain to verify
///         configuration equality without ABI-decoding the full struct.
library ClprConfigHash {
    /// @notice Digest of every field of a `LedgerConfiguration`, including spec
    ///         fields 7 (`trustAnchor`) and 8 (`trustAnchorId`). Encoded as a
    ///         flat ABIv2 tuple of the individual fields (NOT the struct), so
    ///         non-Solidity callers (Java / Go / TS) can reproduce the digest
    ///         without dealing with the extra 32-byte offset pointer that
    ///         `abi.encode(cfg)` would prepend for a dynamic struct.
    /// @dev Off-chain recomputation, in field order:
    ///
    ///        keccak256(abi.encode(
    ///            uint32  protocolVersion,
    ///            string  chainId,
    ///            bytes   serviceAddress,
    ///            uint96  nanosSinceEpoch,
    ///            Throttles throttles,
    ///            bytes   trustAnchor,
    ///            bytes   trustAnchorId
    ///        ))
    ///
    ///      Adding a new field to `LedgerConfiguration` requires adding it to
    ///      this encoding too — there is no automatic forwarding.
    function hashLedgerConfiguration(ClprTypes.LedgerConfiguration memory cfg) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                cfg.protocolVersion,
                cfg.chainId,
                cfg.serviceAddress,
                cfg.nanosSinceEpoch,
                cfg.throttles,
                cfg.trustAnchor,
                cfg.trustAnchorId
            )
        );
    }

    /// @notice Digest of the peer-derived fields stored on a `Channel`. Takes
    ///         the individual fields rather than the full Channel struct so
    ///         it is unambiguous which fields are part of the peer-config
    ///         snapshot vs. local channel state (running hashes, message ids,
    ///         rate-limit counters, etc.).
    /// @dev Per-channel peer roster (signers + endpoint records) is **not**
    ///      included: roster slots contain tombstones (`registered == false`)
    ///      after refresh and the append-with-reuse ordering makes a
    ///      deterministic digest awkward. Add a roster-inclusive variant later
    ///      if needed.
    function hashChannelPeerConfig(
        string memory chainId,
        bytes memory peerServiceAddress,
        uint96 peerConfigTimestamp,
        ClprTypes.Throttles memory peerThrottles,
        bytes memory trustAnchor,
        bytes memory trustAnchorId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(chainId, peerServiceAddress, peerConfigTimestamp, peerThrottles, trustAnchor, trustAnchorId)
        );
    }
}
