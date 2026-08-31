// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title StubBundleContentVerifier
/// @notice Verifier that treats `proofBytes` as a raw protobuf-encoded
///         `ClprBundleContent` and performs no cryptographic verification.
/// @dev Mirrors the Hiero stub-verifier path described in
///      `clpr_bundle_content.proto` ("the submitBundle handler parses
///      bundle_payload directly as this message type"). Useful for
///      Hiero-to-Hiero channels during bring-up and for end-to-end
///      tests that exercise the protobuf wire format without a real
///      proof system. NOT safe for production use across untrusted
///      ledgers — there is no proof that the metadata or messages are
///      authentic.
contract StubBundleContentVerifier is IClprVerifier {
    /// @inheritdoc IClprVerifier
    function verifyBundle(bytes calldata proofBytes, bytes calldata, bytes calldata)
        external
        pure
        override
        returns (
            ClprTypes.QueueMetadata memory metadata,
            bytes[] memory messagePayloads,
            bytes memory newTrustAnchor,
            bytes memory newTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory newEndpointManifest
        )
    {
        (metadata, messagePayloads) = ClprProtobuf.decodeBundleContent(proofBytes);
        // Stateless: trust anchor never advances; no manifest proof (absent = version 0).
        newTrustAnchorId = "";
        newTrustAnchor = "";
        newEndpointManifest.endpoints = new ClprTypes.Endpoint[](0);
    }

    /// @inheritdoc IClprVerifier
    /// @dev The stub verifier does not interpret config proofs. Channels
    ///      using this verifier must be registered with empty/trivial config
    ///      proofs in test harnesses.
    function verifyConfig(
        bytes calldata,
        bytes32, /* channelId */
        bytes calldata /* endpointManifestProofBytes */
    )
        external
        pure
        override
        returns (
            bytes memory channelContext,
            string memory chainId,
            bytes memory peerServiceAddress,
            uint96 peerConfigNanos,
            ClprTypes.Throttles memory throttles,
            bytes memory initialTrustAnchor,
            bytes memory initialTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory endpointManifest
        )
    {
        // Empty but valid manifest at version 1.
        endpointManifest.version = 1;
        endpointManifest.endpoints = new ClprTypes.Endpoint[](0);
        return (new bytes(0), "", "", 0, ClprTypes.Throttles(0, 0, 0, 0, 0, 0, 0), "", "", endpointManifest);
    }
}
