// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "../../src/libraries/ClprTypes.sol";
import {ClprTestBase} from "../helpers/ClprTestBase.sol";

/// @notice Branch coverage for ManifestLib paths the endpoint-manager tests.
contract ManifestLibTest is ClprTestBase {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    function setUp() public override {
        service = _deployClprService(1, "eip155:1337");
        // The service deploys disabled (spec §7); bootstrap it so the mutating
        // endpoint-manifest calls under test are not blocked by ClprDisabled.
        _initializeAndEnable();
        vm.deal(alice, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function _ep(bytes memory accountId) internal pure returns (ClprTypes.Endpoint memory) {
        return ClprTypes.Endpoint({ipAddress: "127.0.0.1", port: 50211, tlsCertificate: hex"", accountId: accountId});
    }

    /// @dev One batch exercising every removal branch: a nonexistent account,
    ///      a PENDING entry (bond refund, no live-set change), a LIVE entry with no bond
    ///      (direct-added), and a LIVE entry with a bond.
    function test_batchRemove_coversEveryStatusClass() public {
        vm.prank(alice); // PENDING with bond
        service.registerEndpoint{value: 0.5 ether}(_ep(hex"01"));
        service.addEndpoint(bob, _ep(hex"02")); // LIVE, no bond
        vm.prank(carol);
        service.registerEndpoint{value: 0.25 ether}(_ep(hex"03"));
        service.addEndpoint(carol, _ep(hex"03")); // LIVE with bond
        assertEq(service.endpointCount(), 2);

        address[] memory removals = new address[](4);
        removals[0] = makeAddr("never-registered"); // NONE → skipped
        removals[1] = alice; // PENDING → refund, not live
        removals[2] = bob; // LIVE, bond == 0
        removals[3] = carol; // LIVE, bond > 0
        service.updateEndpointManifest(new ClprTypes.ManifestUpdateEntry[](0), removals);

        assertEq(service.endpointCount(), 0, "both live entries removed");
        assertEq(service.pendingWithdrawals(alice), 0.5 ether, "pending bond refunded");
        assertEq(service.pendingWithdrawals(bob), 0, "no-bond entry refunds nothing");
        assertEq(service.pendingWithdrawals(carol), 0.25 ether, "live bond refunded");
    }

    function test_addEndpoint_revert_alreadyLive() public {
        service.addEndpoint(bob, _ep(hex"02"));
        vm.expectRevert(ClprTypes.ClprEndpointAlreadyRegistered.selector);
        service.addEndpoint(bob, _ep(hex"02"));
    }

    function test_addEndpoint_revert_manifestFull() public {
        defaultThrottles.maxLocalEndpoints = 1;
        service.updateLedgerConfiguration(hex"1234", defaultThrottles, "", "");

        service.addEndpoint(bob, _ep(hex"02"));
        vm.expectRevert(ClprTypes.ClprEndpointManifestFull.selector);
        service.addEndpoint(carol, _ep(hex"03"));
    }

    /// @dev Removing the LAST live entry takes _removeLive's no-swap path (idx == lastIdx).
    function test_removeEndpoint_lastEntry_noSwap() public {
        service.addEndpoint(bob, _ep(hex"02"));
        service.addEndpoint(carol, _ep(hex"03"));

        service.removeEndpoint(carol); // last in liveAccounts — pop without swap
        assertEq(service.endpointCount(), 1);
        assertEq(service.getEndpointManifest().endpoints[0].accountId, hex"02", "bob remains at index 0");
    }
}
