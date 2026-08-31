// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ClprServiceStorageSlots} from "@test/helpers/ClprServiceStorageSlots.sol";

/// @notice Global ETH liability sums for invariant tests (`VM.getMappingLength` / `getMappingSlotAt`).
/// @dev Requires `VM.startMappingRecording()` before any writes to the tracked mappings (see `ClprInvariantTest.setUp`).
library ClprInvariantEthLib {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `ClprTypes.Connector.lockedStake` struct member slot (see `storage-layout.json`).
    uint256 internal constant CONNECTOR_LOCKED_STAKE_MEMBER = 3;

    function sumGlobalLiabilities(address service) internal view returns (uint256) {
        return sumConnectorLockedStake(service) + sumEndpointBonds(service) + sumPendingWithdrawals(service);
    }

    function sumConnectorLockedStake(address service) internal view returns (uint256 total) {
        bytes32 existsMap = bytes32(ClprServiceStorageSlots.CONNECTOR_EXISTS);
        uint256 len = VM.getMappingLength(service, existsMap);
        for (uint256 i = 0; i < len; i++) {
            bytes32 existsValueSlot = VM.getMappingSlotAt(service, existsMap, i);
            if (uint256(VM.load(service, existsValueSlot)) == 0) continue;

            (bool found, bytes32 connectorKey,) = VM.getMappingKeyAndParentOf(service, existsValueSlot);
            if (!found) continue;

            bytes32 connectorBase = keccak256(abi.encode(connectorKey, ClprServiceStorageSlots.CONNECTORS));
            total += uint256(VM.load(service, bytes32(uint256(connectorBase) + CONNECTOR_LOCKED_STAKE_MEMBER)));
        }
    }

    /// @dev Sums escrowed endpoint bonds across the local manifest's `entries` mapping (both PENDING
    ///      and LIVE entries hold a bond). Enumerated via mapping recording on the entries slot.
    function sumEndpointBonds(address service) internal view returns (uint256 total) {
        bytes32 entriesMap = bytes32(ClprServiceStorageSlots.ENDPOINT_MANIFEST_ENTRIES);
        uint256 len = VM.getMappingLength(service, entriesMap);
        for (uint256 i = 0; i < len; i++) {
            bytes32 entryBase = VM.getMappingSlotAt(service, entriesMap, i); // struct base = keccak(key, slot)
            total += uint256(
                VM.load(service, bytes32(uint256(entryBase) + ClprServiceStorageSlots.ENDPOINT_ENTRY_BOND_MEMBER))
            );
        }
    }

    function sumPendingWithdrawals(address service) internal view returns (uint256 total) {
        bytes32 pendingMap = bytes32(ClprServiceStorageSlots.PENDING_WITHDRAWALS);
        uint256 len = VM.getMappingLength(service, pendingMap);
        for (uint256 i = 0; i < len; i++) {
            bytes32 pendingValueSlot = VM.getMappingSlotAt(service, pendingMap, i);
            total += uint256(VM.load(service, pendingValueSlot));
        }
    }
}
