// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprServiceStorage} from "@hiero-ledger/clpr/ClprServiceStorage.sol";

/// @title LogicModuleBase
/// @notice Abstract base contract for all CLPR logic modules.
/// Provides common authorization and kill-switch patterns.
///
/// @dev All logic modules must inherit this contract to ensure consistent
/// storage layout and authorization semantics. This contract is never deployed
/// directly; it exists only as a base for ChannelLogic, MessagingLogic,
/// BundleLogic, ConnectorLogic, and AdminLogic.
///
/// Inheritance chain:
///   LogicModuleBase -> ClprServiceStorage -> ReentrancyGuardTransient
///
/// Authorization ensures that only ClprService (via DELEGATECALL) can invoke
/// protected functions. When a logic module is called via DELEGATECALL from
/// ClprService, address(this) in the logic contract's context resolves to
/// ClprService's address, which matches _authorizedService.
abstract contract LogicModuleBase is ClprServiceStorage {
    /// @dev Shared across all logic modules. Reverted when a non-service caller
    /// attempts to invoke a function protected by onlyService().
    error UnauthorizedCaller();

    // ── Service Authorization ──────────────────────────────────────────────

    /// @notice Modifier that restricts execution to the authorized ClprService.
    /// @dev address(this) == ClprService address when called via DELEGATECALL.
    /// Reverts with UnauthorizedCaller if invoked from any other context.
    modifier onlyService() {
        if (address(this) != _authorizedService) revert UnauthorizedCaller();
        _;
    }

    // ── Kill-switch Modifier ───────────────────────────────────────────────

    /// @notice Modifier that enforces the global enable flag.
    /// @dev Calls _checkEnabled() which reverts with ClprDisabled() if the
    /// service is not enabled. Applied to all state-mutating functions to
    /// provide a global kill switch for the entire protocol.
    modifier whenEnabled() {
        _checkEnabled();
        _;
    }

    /// @notice Modifier that requires initialize() to have already been called.
    /// @dev Calls _checkInitialized() which reverts with ClprNotInitialized() if
    /// initialize() has not run yet. Once initialize() has run, this never blocks
    /// again (there is no un-initializing).
    modifier whenInitialized() {
        _checkInitialized();
        _;
    }
}
