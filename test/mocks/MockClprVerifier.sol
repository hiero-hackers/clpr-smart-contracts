// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

contract MockClprVerifier is IClprVerifier {
    ClprTypes.QueueMetadata private _metadata;
    bytes[] private _messagePayloads;
    bytes private _newTrustAnchor;
    bytes private _newTrustAnchorId;
    string private _chainId;
    bytes private _serviceAddress;
    uint96 private _peerConfigNanos;
    ClprTypes.Throttles private _peerThrottles;
    bytes private _initialTrustAnchor;
    bytes private _initialTrustAnchorId;
    bool private _shouldRevert;
    string private _revertReason;
    // Initial peer manifest returned by verifyConfig, and the (optional) manifest returned by verifyBundle.
    ClprTypes.ClprEndpointManifest private _endpointManifest;
    ClprTypes.ClprEndpointManifest private _newEndpointManifest;

    function setVerifyBundleResult(ClprTypes.QueueMetadata memory metadata, bytes[] memory messagePayloads) external {
        _metadata = metadata;
        delete _messagePayloads;
        for (uint256 i = 0; i < messagePayloads.length; i++) {
            _messagePayloads.push(messagePayloads[i]);
        }
    }

    /// @notice Set the initial peer manifest returned by verifyConfig.
    function setEndpointManifest(ClprTypes.ClprEndpointManifest memory manifest) external {
        _endpointManifest = manifest;
    }

    /// @notice Set the manifest returned by verifyBundle (version 0 = absent).
    function setNewEndpointManifest(ClprTypes.ClprEndpointManifest memory manifest) external {
        _newEndpointManifest = manifest;
    }

    /// @notice Backward-compat shim: wrap an endpoint list into the initial (version-1) manifest that
    ///         verifyConfig returns. Retained so existing tests that seeded endpoints still work.
    /// @dev Deliberately does NOT run validation - purpose of this mock is to allow
    //       injecting arbitrary data, no matter if correct or not.
    function setSeedEndpoints(ClprTypes.Endpoint[] memory endpoints) external {
        _endpointManifest.version = 1;
        _endpointManifest.serviceAddress = _serviceAddress;
        delete _endpointManifest.endpoints;
        for (uint256 i = 0; i < endpoints.length; i++) {
            _endpointManifest.endpoints.push(endpoints[i]);
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

    function setShouldRevert(bool shouldRevert, string memory reason) external {
        _shouldRevert = shouldRevert;
        _revertReason = reason;
    }

    /// @notice For tests: how many endpoints the verifyConfig manifest carries.
    function endpointCount() external view returns (uint256) {
        return _endpointManifest.endpoints.length;
    }

    /// @notice Backward-compat alias for {endpointCount}.
    function seedEndpointCount() external view returns (uint256) {
        return _endpointManifest.endpoints.length;
    }

    /// @notice Backward-compat alias for {getEndpoint}.
    function getSeedEndpoint(uint256 index) external view returns (ClprTypes.Endpoint memory) {
        require(index < _endpointManifest.endpoints.length, "MockClprVerifier: seed index OOB");
        return _endpointManifest.endpoints[index];
    }

    /// @notice For tests: read one manifest endpoint by index (reverts if out of range).
    function getEndpoint(uint256 index) external view returns (ClprTypes.Endpoint memory) {
        require(index < _endpointManifest.endpoints.length, "MockClprVerifier: endpoint index OOB");
        return _endpointManifest.endpoints[index];
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
        if (_shouldRevert) revert(_revertReason);
        return (_metadata, _messagePayloads, _newTrustAnchor, _newTrustAnchorId, _newEndpointManifest);
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
        if (_shouldRevert) revert(_revertReason);
        channelContext = ClprTypes.encodeChannelContext(
            ClprTypes.ChannelContext({channelId: channelId, remoteServiceAddress: _serviceAddress})
        );
        return (
            channelContext,
            _chainId,
            _serviceAddress,
            _peerConfigNanos,
            _peerThrottles,
            _initialTrustAnchor,
            _initialTrustAnchorId,
            _endpointManifest
        );
    }
}
