// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title HieroE2EVerifier
/// @notice Test-only thin wrapper around a production `IClprVerifier` (the `HieroVerifier`)
///         for the Besu ↔ Hiero E2E suite driven by the real clpr-evm-endpoint relay.
///
/// @dev NOT a stub: `verifyBundle` and `verifyConfig` delegate verbatim to the wrapped
///      verifier, so the full cryptographic verification (TSS / state proofs / trust-anchor and
///      chainId / serviceAddress derivation) runs unchanged.
///
///      The only thing the wrapper adds is the peer-endpoint seed. The production HieroVerifier's
///      `verifyConfig` derives the endpoint manifest from a real manifest state proof; the
///      bring-up path supplies an empty proof, so a freshly-completed channel has an empty
///      on-chain peer manifest and the relay (which discovers its peer via `getPeerEndpointManifest`)
///      would never find anyone to sync with. We inject the peer's gRPC endpoint here via
///      `setSeedEndpoints`, so `completeChannel` bootstraps a usable manifest — mirroring
///      `QbftE2EVerifier` on the Besu ↔ Besu path.
contract HieroE2EVerifier is IClprVerifier {
    IClprVerifier public immutable inner;
    ClprTypes.Endpoint[] private _seedEndpoints;

    constructor(IClprVerifier inner_) {
        inner = inner_;
    }

    /// @notice One-shot configuration of the peer's seed endpoint(s) returned by `verifyConfig`.
    ///         Caller is trusted (test harness only).
    function setSeedEndpoints(ClprTypes.Endpoint[] calldata seedEndpoints) external {
        delete _seedEndpoints;
        for (uint256 i = 0; i < seedEndpoints.length; i++) {
            _seedEndpoints.push(seedEndpoints[i]);
        }
    }

    /// @inheritdoc IClprVerifier
    /// @dev Real verification — delegated verbatim to the wrapped verifier.
    function verifyBundle(bytes calldata proofBytes, bytes calldata trustAnchor, bytes calldata channelContext)
        external
        view
        override
        returns (
            ClprTypes.QueueMetadata memory metadata,
            bytes[] memory messagePayloads,
            bytes memory newTrustAnchor,
            bytes memory newTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory newEndpointManifest
        )
    {
        return inner.verifyBundle(proofBytes, trustAnchor, channelContext);
    }

    /// @inheritdoc IClprVerifier
    /// @dev Delegates to the wrapped verifier for everything (chainId / serviceAddress / throttles /
    ///      trust anchor are all derived from the config proof + channelId), then substitutes the
    ///      configured seed endpoints as the initial peer manifest so `completeChannel`
    ///      bootstraps a usable manifest for e2e sync.
    function verifyConfig(bytes calldata configProofBytes, bytes32 channelId, bytes calldata endpointManifestProofBytes)
        external
        view
        override
        returns (
            bytes memory channelContext,
            string memory chainId,
            bytes memory serviceAddress,
            uint96 peerConfigNanos,
            ClprTypes.Throttles memory throttles,
            bytes memory initialTrustAnchor,
            bytes memory initialTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory endpointManifest
        )
    {
        (
            channelContext,
            chainId,
            serviceAddress,
            peerConfigNanos,
            throttles,
            initialTrustAnchor,
            initialTrustAnchorId,
        ) = inner.verifyConfig(configProofBytes, channelId, endpointManifestProofBytes);
        endpointManifest =
            ClprTypes.ClprEndpointManifest({version: 1, serviceAddress: serviceAddress, endpoints: _seedEndpoints});
    }
}
