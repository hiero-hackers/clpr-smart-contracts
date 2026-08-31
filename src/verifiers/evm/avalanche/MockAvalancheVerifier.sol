// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title MockAvalancheVerifier
/// @notice Test verifier for Avalanche C-Chain end-to-end tests.
/// @dev No cryptographic verification — used only in test harnesses.
///      Decodes bundles properly and has configurable verifyConfig values.
contract MockAvalancheVerifier is IClprVerifier {
    string private _chainId;
    bytes private _serviceAddress;
    uint96 private _peerConfigNanos;
    ClprTypes.Throttles private _peerThrottles;
    bytes private _initialTrustAnchor;
    bytes private _initialTrustAnchorId;
    ClprTypes.Endpoint[] private _seedEndpoints;

    /// @notice One-shot configuration. Caller is trusted (test harness only).
    function configure(
        string calldata chainId,
        bytes calldata serviceAddress,
        uint96 peerConfigNanos,
        ClprTypes.Throttles calldata throttles,
        bytes calldata initialTrustAnchor,
        bytes calldata initialTrustAnchorId,
        ClprTypes.Endpoint[] calldata seedEndpoints
    ) external {
        _chainId = chainId;
        _serviceAddress = serviceAddress;
        _peerConfigNanos = peerConfigNanos;
        _peerThrottles = throttles;
        _initialTrustAnchor = initialTrustAnchor;
        _initialTrustAnchorId = initialTrustAnchorId;
        delete _seedEndpoints;
        for (uint256 i = 0; i < seedEndpoints.length; i++) {
            _seedEndpoints.push(seedEndpoints[i]);
        }
    }

    /// @inheritdoc IClprVerifier
    function verifyBundle(bytes calldata proofBytes, bytes calldata, bytes calldata)
        external
        pure
        returns (
            ClprTypes.QueueMetadata memory metadata,
            bytes[] memory messagePayloads,
            bytes memory newTrustAnchor,
            bytes memory newTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory newEndpointManifest
        )
    {
        (metadata, messagePayloads) = ClprProtobuf.decodeBundleContent(proofBytes);
        newTrustAnchor = "";
        newTrustAnchorId = "";
        newEndpointManifest.endpoints = new ClprTypes.Endpoint[](0);
    }

    /// @inheritdoc IClprVerifier
    function verifyConfig(bytes calldata, bytes32, bytes calldata)
        external
        view
        returns (
            bytes memory channelContext,
            string memory chainId,
            bytes memory peerServiceAddress,
            uint96 peerConfigNanos,
            ClprTypes.Throttles memory peerThrottles,
            bytes memory initialTrustAnchor,
            bytes memory initialTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory endpointManifest
        )
    {
        channelContext = new bytes(0); // mock — no real context
        endpointManifest =
            ClprTypes.ClprEndpointManifest({version: 1, serviceAddress: _serviceAddress, endpoints: _seedEndpoints});
        return (
            channelContext,
            _chainId,
            _serviceAddress,
            _peerConfigNanos,
            _peerThrottles,
            _initialTrustAnchor,
            _initialTrustAnchorId,
            endpointManifest
        );
    }
}
