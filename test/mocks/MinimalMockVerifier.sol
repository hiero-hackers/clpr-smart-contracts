// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @notice Minimal mock verifier for gas benchmarking - optimized for minimal gas usage.
/// @dev Stores all payloads to support multi-message tests while maintaining low gas overhead.
contract MinimalMockVerifier is IClprVerifier {
    // Cached results stored in memory during setup, then returned directly
    ClprTypes.QueueMetadata private _metadata;
    bytes[] private _messagePayloads;
    bytes private _newTrustAnchor;
    bytes private _newTrustAnchorId;

    // Config results
    string private _chainId;
    bytes private _serviceAddress;
    uint96 private _peerConfigNanos;
    ClprTypes.Throttles private _peerThrottles;
    bytes private _initialTrustAnchor;
    bytes private _initialTrustAnchorId;
    ClprTypes.Endpoint[] private _seedEndpoints;

    function setVerifyBundleResult(ClprTypes.QueueMetadata memory metadata, bytes[] memory messagePayloads) external {
        _metadata = metadata;
        delete _messagePayloads;
        for (uint256 i = 0; i < messagePayloads.length; i++) {
            _messagePayloads.push(messagePayloads[i]);
        }
    }

    function setNewTrustAnchor(bytes calldata newTrustAnchor) external {
        _newTrustAnchor = newTrustAnchor;
    }

    function setNewTrustAnchorId(bytes calldata newTrustAnchorId) external {
        _newTrustAnchorId = newTrustAnchorId;
    }

    function setVerifyConfigResult(string memory chainId, bytes memory serviceAddress, uint96 peerConfigNanos)
        external
    {
        _chainId = chainId;
        _serviceAddress = serviceAddress;
        _peerConfigNanos = peerConfigNanos;
    }

    function setPeerThrottles(ClprTypes.Throttles memory throttles) external {
        _peerThrottles = throttles;
    }

    function setInitialTrustAnchor(bytes memory initialTrustAnchor) external {
        _initialTrustAnchor = initialTrustAnchor;
    }

    function setInitialTrustAnchorId(bytes memory initialTrustAnchorId) external {
        _initialTrustAnchorId = initialTrustAnchorId;
    }

    /// @dev Deliberately does NOT run validation - purpose of this mock is to allow
    //       injecting arbitrary data, no matter if correct or not.
    function setSeedEndpoints(ClprTypes.Endpoint[] memory endpoints) external {
        delete _seedEndpoints;
        for (uint256 i = 0; i < endpoints.length; i++) {
            _seedEndpoints.push(endpoints[i]);
        }
    }

    function verifyBundle(bytes calldata, bytes calldata, bytes calldata)
        external
        view
        override
        returns (
            ClprTypes.QueueMetadata memory,
            bytes[] memory,
            bytes memory,
            bytes memory,
            ClprTypes.ClprEndpointManifest memory
        )
    {
        return (_metadata, _messagePayloads, _newTrustAnchor, _newTrustAnchorId, _emptyManifest());
    }

    function verifyConfig(bytes calldata, bytes32 channelId, bytes calldata)
        external
        view
        override
        returns (
            bytes memory channelContext,
            string memory,
            bytes memory,
            uint96,
            ClprTypes.Throttles memory,
            bytes memory,
            bytes memory,
            ClprTypes.ClprEndpointManifest memory
        )
    {
        channelContext = ClprTypes.encodeChannelContext(
            ClprTypes.ChannelContext({channelId: channelId, remoteServiceAddress: _serviceAddress})
        );
        ClprTypes.ClprEndpointManifest memory manifest =
            ClprTypes.ClprEndpointManifest({version: 1, serviceAddress: _serviceAddress, endpoints: _seedEndpoints});
        return (
            channelContext,
            _chainId,
            _serviceAddress,
            _peerConfigNanos,
            _peerThrottles,
            _initialTrustAnchor,
            _initialTrustAnchorId,
            manifest
        );
    }

    /// @dev An absent manifest (version 0) for verifyBundle when no manifest proof is present.
    function _emptyManifest() private pure returns (ClprTypes.ClprEndpointManifest memory m) {
        m.endpoints = new ClprTypes.Endpoint[](0);
    }
}
