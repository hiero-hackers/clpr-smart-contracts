// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {EndpointValidation} from "@hiero-ledger/clpr/libraries/service/EndpointValidation.sol";

/// @title ManifestLib
/// @notice Stateless library maintaining a CLPR Service's versioned local endpoint manifest — the on-ledger endpoint
///         set advertised to peers.
/// @dev Two-step admission: `registerEndpoint` creates a PENDING entry holding a bond, and the
///      admin promotes it to LIVE via `addEndpoint` / `updateEndpointManifest`. Bonds are escrowed
///      by ClprService and credited back to `pendingWithdrawals` in full on any exit. Every
///      function takes explicit storage pointers so it operates on ClprService's storage.
library ManifestLib {
    /// @notice A caller self-registered as a pending endpoint (bond escrowed; not yet live).
    event EndpointRegistered(address indexed registrant, uint256 bond);
    /// @notice The admin admitted an endpoint to the live manifest.
    event EndpointAdmitted(address indexed registrant, uint64 version);
    /// @notice An endpoint was removed (self-exit or admin eviction) or a pending registration cancelled.
    event EndpointRemoved(address indexed registrant, bool wasLive, uint256 bondReturned, uint64 version);
    /// @notice A batch manifest update was applied atomically.
    event EndpointManifestUpdated(uint64 version, uint256 liveCount);

    /// @notice Self-register `registrant` as a PENDING endpoint holding `bond`.
    /// @dev Leaves the live set and the version untouched — a pending entry is not in the manifest.
    function registerEndpoint(
        ClprTypes.EndpointManifestState storage s,
        ClprTypes.Endpoint calldata endpoint,
        uint256 bond,
        uint256 minBond,
        address registrant
    ) internal {
        if (s.entries[registrant].status != ClprTypes.EndpointStatus.NONE) {
            revert ClprTypes.ClprEndpointAlreadyRegistered();
        }
        if (bond < minBond) revert ClprTypes.ClprInsufficientBond();
        _validateEndpoint(endpoint);

        s.entries[registrant] =
            ClprTypes.EndpointManifestEntry({endpoint: endpoint, bond: bond, status: ClprTypes.EndpointStatus.PENDING});

        emit EndpointRegistered(registrant, bond);
    }

    /// @notice Admin: admit `registrant` to the live manifest and bump the version by 1. A PENDING
    ///         entry is promoted using its self-registered data (`endpoint` is ignored); otherwise
    ///         `endpoint` is added directly with no bond.
    function addEndpoint(
        ClprTypes.EndpointManifestState storage s,
        address registrant,
        ClprTypes.Endpoint calldata endpoint,
        uint32 maxLocalEndpoints,
        bytes memory serviceAddress
    ) internal returns (uint64 newVersion) {
        _addEndpoint(s, registrant, endpoint, maxLocalEndpoints);
        newVersion = _bumpVersion(s, serviceAddress);
        emit EndpointAdmitted(registrant, newVersion);
    }

    /// @notice Remove `registrant` from the live manifest, or cancel its pending registration. The
    ///         bond is credited in full to `pendingWithdrawals[registrant]`. The version is bumped
    ///         only if the entry was LIVE — cancelling a pending registration leaves the manifest
    ///         unchanged.
    function removeEndpoint(
        ClprTypes.EndpointManifestState storage s,
        mapping(address => uint256) storage pendingWithdrawals,
        address registrant,
        bytes memory serviceAddress
    ) internal returns (uint64 version, bool wasLive) {
        ClprTypes.EndpointManifestEntry storage entry = s.entries[registrant];
        ClprTypes.EndpointStatus status = entry.status;
        if (status == ClprTypes.EndpointStatus.NONE) revert ClprTypes.ClprEndpointNotRegistered();

        wasLive = status == ClprTypes.EndpointStatus.LIVE;
        uint256 bond = entry.bond;

        if (wasLive) _removeLive(s, registrant);
        delete s.entries[registrant];
        if (bond > 0) pendingWithdrawals[registrant] += bond;

        version = wasLive ? _bumpVersion(s, serviceAddress) : _currentVersion(s);
        emit EndpointRemoved(registrant, wasLive, bond, version);
    }

    /// @notice Admin: atomically apply a batch of removals then additions, bumping the version at
    ///         most once. Removals refund bonds in full and skip entries that do not exist;
    ///         additions revert if the registrant is already LIVE or the manifest is full.
    /// @dev Removals are deliberately applied BEFORE additions so the `maxLocalEndpoints` cap is
    ///      checked against the post-removal live count — an atomic swap (remove one, add one)
    ///      therefore succeeds at full capacity. Only the final state is observable either way.
    function updateEndpointManifest(
        ClprTypes.EndpointManifestState storage s,
        mapping(address => uint256) storage pendingWithdrawals,
        ClprTypes.ManifestUpdateEntry[] calldata addressesToAdd,
        address[] calldata addressesToRemove,
        uint32 maxLocalEndpoints,
        bytes memory serviceAddress
    ) internal returns (uint64 newVersion) {
        bool changed = addressesToAdd.length != 0;

        for (uint256 i = 0; i < addressesToRemove.length; i++) {
            address registrant = addressesToRemove[i];
            ClprTypes.EndpointManifestEntry storage entry = s.entries[registrant];
            ClprTypes.EndpointStatus status = entry.status;
            if (status == ClprTypes.EndpointStatus.NONE) continue;
            uint256 bond = entry.bond;
            if (status == ClprTypes.EndpointStatus.LIVE) {
                _removeLive(s, registrant);
                changed = true;
            }
            delete s.entries[registrant];
            if (bond > 0) pendingWithdrawals[registrant] += bond;
        }

        for (uint256 i = 0; i < addressesToAdd.length; i++) {
            _addEndpoint(s, addressesToAdd[i].registrantAccount, addressesToAdd[i].endpoint, maxLocalEndpoints);
        }

        newVersion = changed ? _bumpVersion(s, serviceAddress) : _currentVersion(s);
        emit EndpointManifestUpdated(newVersion, s.liveAccounts.length);
    }

    /// @notice Build the current live `ClprEndpointManifest` for `serviceAddress`.
    /// @dev Version is normalized to >= 1: an uninitialized `0` reads as the empty manifest at version 1.
    function getManifest(ClprTypes.EndpointManifestState storage s, bytes memory serviceAddress)
        internal
        view
        returns (ClprTypes.ClprEndpointManifest memory m)
    {
        uint256 n = s.liveAccounts.length;
        ClprTypes.Endpoint[] memory eps = new ClprTypes.Endpoint[](n);
        for (uint256 i = 0; i < n; i++) {
            eps[i] = s.entries[s.liveAccounts[i]].endpoint;
        }
        m.version = _currentVersion(s);
        m.serviceAddress = serviceAddress;
        m.endpoints = eps;
    }

    /// @notice The number of endpoints currently in the live manifest.
    function liveCount(ClprTypes.EndpointManifestState storage s) internal view returns (uint256) {
        return s.liveAccounts.length;
    }

    /// @notice Recompute `s.commitment` over the current live manifest without changing the version.
    /// @dev Called at construction (so the genesis empty manifest is provable via the commitment
    ///      slot) and whenever `serviceAddress` changes — the address is part of the committed
    ///      encoding, so a stale commitment would fail every manifest proof until the next
    ///      endpoint change.
    function syncCommitment(ClprTypes.EndpointManifestState storage s, bytes memory serviceAddress) internal {
        s.commitment = keccak256(ClprProtobuf.encodeEndpointManifest(getManifest(s, serviceAddress)));
    }

    // ── Internal helpers ────────────────────────────────────────────────────────

    function _addEndpoint(
        ClprTypes.EndpointManifestState storage s,
        address registrant,
        ClprTypes.Endpoint calldata endpoint,
        uint32 maxLocalEndpoints
    ) private {
        ClprTypes.EndpointStatus status = s.entries[registrant].status;
        if (status == ClprTypes.EndpointStatus.LIVE) revert ClprTypes.ClprEndpointAlreadyRegistered();
        if (maxLocalEndpoints != 0 && s.liveAccounts.length >= maxLocalEndpoints) {
            revert ClprTypes.ClprEndpointManifestFull();
        }

        if (status == ClprTypes.EndpointStatus.PENDING) {
            s.entries[registrant].status = ClprTypes.EndpointStatus.LIVE;
        } else {
            _validateEndpoint(endpoint);
            s.entries[registrant] =
                ClprTypes.EndpointManifestEntry({endpoint: endpoint, bond: 0, status: ClprTypes.EndpointStatus.LIVE});
        }
        _pushLive(s, registrant);
    }

    /// @dev Validate discovery data on every intake path (self-registration and direct admin adds);
    ///      promoting a PENDING entry reuses data that was already validated.
    function _validateEndpoint(ClprTypes.Endpoint calldata endpoint) private pure {
        EndpointValidation.validateIpAddress(endpoint.ipAddress);
        EndpointValidation.validateTlsCertificate(endpoint.tlsCertificate);
    }

    function _currentVersion(ClprTypes.EndpointManifestState storage s) private view returns (uint64) {
        return s.version == 0 ? 1 : s.version;
    }

    /// @dev Increment the version and refresh the commitment over the new live manifest.
    function _bumpVersion(ClprTypes.EndpointManifestState storage s, bytes memory serviceAddress)
        private
        returns (uint64 newVersion)
    {
        newVersion = _currentVersion(s) + 1;
        s.version = newVersion;
        syncCommitment(s, serviceAddress);
    }

    function _pushLive(ClprTypes.EndpointManifestState storage s, address registrant) private {
        s.liveAccounts.push(registrant);
        s.liveCounter[registrant] = s.liveAccounts.length; // 1-based
    }

    /// @dev O(1) swap-remove of `registrant` from the live list.
    function _removeLive(ClprTypes.EndpointManifestState storage s, address registrant) private {
        uint256 idx = s.liveCounter[registrant];
        if (idx == 0) return; // not live
        uint256 lastIdx = s.liveAccounts.length;
        if (idx != lastIdx) {
            address moved = s.liveAccounts[lastIdx - 1];
            s.liveAccounts[idx - 1] = moved;
            s.liveCounter[moved] = idx;
        }
        s.liveAccounts.pop();
        delete s.liveCounter[registrant];
    }
}
