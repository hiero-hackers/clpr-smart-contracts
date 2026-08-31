// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ConnectorLib} from "@hiero-ledger/clpr/libraries/service/ConnectorLib.sol";
import {LogicModuleBase} from "@hiero-ledger/clpr/logic/base/LogicModuleBase.sol";

/// @title ConnectorLogic
/// @notice Connector lifecycle: register, complete, remove, and inspect connectors.
/// @dev Executed via delegatecall from ClprService. All state reads and writes
///      operate on ClprServiceStorage slots in the router's storage.
contract ConnectorLogic is LogicModuleBase {
    constructor() {}

    // ── Public views ───────────────────────────────────────────────────────

    /// @notice Returns true if `commitment` has been registered but not yet revealed.
    /// @param commitment The commitment hash to check.
    function pendingConnectorCommitments(bytes32 commitment) external view returns (bool) {
        return _pendingConnectorCommitments[commitment];
    }

    /// @notice Total number of registered connectors across all channels.
    function connectorCount() external view returns (uint256) {
        return _connectorCount;
    }

    /// @notice Returns the connector record for the given channel and connector ID.
    /// @dev Reverts with `ClprConnectorNotFound` if the connector does not exist.
    /// @param channelId The parent channel.
    /// @param connectorId The connector identifier derived via deriveConnectorId.
    function getConnector(bytes32 channelId, bytes32 connectorId) external view returns (ClprTypes.Connector memory) {
        return ConnectorLib.get(_connectors, _connectorExists, channelId, connectorId);
    }

    /// @notice Returns true if the connector exists on the given channel.
    /// @param channelId The parent channel.
    /// @param connectorId The connector identifier to check.
    function hasConnector(bytes32 channelId, bytes32 connectorId) external view returns (bool) {
        return ConnectorLib.has(_connectorExists, channelId, connectorId);
    }

    /// @notice Compute the deterministic connector identifier.
    /// @dev Formula: abi.encodePacked(keccak256(channelId || pubKey || salt)).
    ///      The result is 32 bytes packed as a `bytes` value, distinct per
    ///      (channel, key, salt) triple.
    /// @param channelId The channel to scope the connector to.
    /// @param pubKey Raw 64-byte uncompressed ECDSA public key of the connector operator.
    /// @param salt Caller-chosen entropy to allow multiple connectors per key.
    /// @return Deterministic connector identifier (32 bytes encoded as bytes).
    function deriveConnectorId(bytes32 channelId, bytes calldata pubKey, bytes32 salt) external pure returns (bytes32) {
        return ConnectorLib.deriveConnectorId(channelId, pubKey, salt);
    }

    // ── Connector lifecycle ────────────────────────────────────────────────

    /// @notice Register a connector commitment (commit phase of commit-reveal).
    /// @dev Anyone may commit; ECDSA ownership is enforced during completeConnector.
    /// @param commitment keccak256(connectorId || pubKey) binding the reveal.
    function registerConnector(bytes32 commitment) external onlyService whenEnabled {
        _pendingConnectorCommitments[commitment] = true;
    }

    /// @notice Reveal and complete a previously registered connector commitment.
    /// @dev Validates the commitment, verifies the ECDSA signature over
    ///      keccak256(connectorId || address(this)) — binding the reveal to this
    ///      ClprService deployment — checks connectorId derivation from
    ///      (channelId, pubKey, salt), and records the connector.
    ///      Requires msg.value >= economicConfig.minConnectorBond.
    ///      Emits {ConnectorCompleted}.
    /// @param connectorId Connector identifier derived via deriveConnectorId.
    /// @param pubKey Raw 64-byte uncompressed ECDSA public key.
    /// @param sig ECDSA signature over keccak256(connectorId || address(this)).
    /// @param salt Entropy used when the connectorId was derived.
    /// @param channelId The channel to register the connector on.
    /// @param connectorContract Address of the IClprConnector application contract.
    /// @param admin Address authorised to deregister this connector.
    function completeConnector(
        bytes32 connectorId,
        bytes calldata pubKey,
        bytes calldata sig,
        bytes32 salt,
        bytes32 channelId,
        address connectorContract,
        address admin
    ) external payable onlyService whenEnabled {
        if (!_channelExists[channelId]) revert ClprTypes.ClprChannelNotFound();
        if (economicConfig.maxConnectors > 0 && _connectorCount >= economicConfig.maxConnectors) {
            revert ClprTypes.ClprTooManyConnectors();
        }
        ConnectorLib.completeRegistration(
            _connectors,
            _connectorExists,
            _pendingConnectorCommitments,
            economicConfig,
            connectorId,
            pubKey,
            sig,
            salt,
            channelId,
            connectorContract,
            admin,
            msg.value
        );
        unchecked {
            _connectorCount++;
        }
    }

    /// @notice Remove a connector and return its bond to `recipient`.
    /// @dev Caller must be the connector's admin (enforced in ConnectorLib.deregister).
    ///      Reverts if any messages for this connector are still in-flight.
    ///      Bond is returned via direct ETH transfer; nonReentrant guard prevents
    ///      recursive re-entry.
    /// @param channelId The parent channel.
    /// @param connectorId The connector to remove.
    /// @param recipient Address to receive the returned bond.
    // Caller authorization (admin check) is enforced inside ConnectorLib.deregister.
    function removeConnector(bytes32 channelId, bytes32 connectorId, address recipient)
        external
        nonReentrant
        whenEnabled
    {
        uint256 stake = ConnectorLib.deregister(
            _connectors, _connectorExists, _connectorInflightCount, channelId, connectorId, recipient
        );
        unchecked {
            _connectorCount--;
        }
        if (stake > 0) {
            (bool ok,) = recipient.call{value: stake}("");
            if (!ok) revert ClprTypes.ClprTransferFailed();
        }
    }

    /// @notice Add ETH to an existing connector's bond.
    /// @param channelId The parent channel.
    /// @param connectorId The connector to top up.
    function topUpConnectorStake(bytes32 channelId, bytes32 connectorId) external payable whenEnabled onlyService {
        if (msg.value == 0) revert ClprTypes.ClprInsufficientStake();
        ConnectorLib.topUpStake(_connectors, _connectorExists, channelId, connectorId, msg.value);
    }
}
