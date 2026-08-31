// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ClprService} from "@hiero-ledger/clpr/ClprService.sol";
import {IClprService} from "@hiero-ledger/clpr/interfaces/IClprService.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {MockClprVerifier} from "@test/mocks/MockClprVerifier.sol";
import {MockClprConnector} from "@test/mocks/MockClprConnector.sol";
import {ConnectorRegistrar} from "@test/helpers/ConnectorRegistrar.sol";
import {ClprTestBase} from "@test/helpers/ClprTestBase.sol";

/// @title ClprServiceViewSmoke
/// @notice Bucket A coverage. Exercises every read-only delegator on ClprService
///         at least once so the router's _delegate / _staticDelegate paths and
///         the underlying logic-contract view functions are covered.
contract ClprServiceViewSmokeTest is ClprTestBase {
    uint256 internal connSignerPk = 0xC0DE;

    function setUp() public override {
        super.setUp();

        connectorId = ConnectorRegistrar.register(
            IClprService(address(service)),
            channelId,
            keccak256(abi.encodePacked("smoke-connector")),
            address(connector),
            owner,
            1 ether
        );

        // Register the owner as a pending endpoint, then admit it to the live manifest.
        ClprTypes.Endpoint memory ep =
            ClprTypes.Endpoint({ipAddress: "127.0.0.1", port: 50211, tlsCertificate: "", accountId: hex"01"});
        service.registerEndpoint(ep);
        service.addEndpoint(owner, ep);
    }

    // ── Bucket A: views with zero existing test references ─────────────────

    function test_view_deriveChannelId_matchesCreated() public {
        bytes memory pubKey = _signerPubKey();
        bytes32 derived = service.deriveChannelId("eip155:1", pubKey, testingSalt);
        assertEq(derived, channelId);
    }

    function test_view_channelCount_isOneAfterSetup() public {
        assertEq(service.channelCount(), 1);
    }

    function test_view_connectorCount_isOneAfterSetup() public {
        assertEq(service.connectorCount(), 1);
    }

    function test_view_pendingConnectorCommitments_falseForUnknown() public {
        // ConnectorRegistrar.register completes the registration, which clears the
        // pending commitment. Querying any unset commitment must return false.
        assertFalse(service.pendingConnectorCommitments(keccak256(abi.encodePacked("never-set"))));
    }

    function test_view_getEconomicConfig_returnsConfigured() public {
        ClprTypes.EconomicConfig memory econ = service.getEconomicConfig();
        assertEq(econ.endpointMarginPercent, 10);
        assertEq(econ.connectorQueueQuotaPct, 50);
        assertEq(econ.basePenalty, 0.01 ether);
        assertEq(econ.penaltyMultiplier, 2);
        assertEq(econ.slashBanThreshold, 5);
    }

    // ── Views with sparse coverage: hit revert / edge branches ─────────────

    function test_view_getChannel_returnsActive() public {
        ClprTypes.Channel memory channel = service.getChannel(channelId);
        assertEq(uint8(channel.status), uint8(ClprTypes.ChannelStatus.ACTIVE));
    }

    function test_view_getChannel_revertsIfMissing() public {
        vm.expectRevert(ClprTypes.ClprChannelNotFound.selector);
        service.getChannel(keccak256(abi.encodePacked("does-not-exist")));
    }

    function test_view_getConnector_revertsIfMissing() public {
        vm.expectRevert(ClprTypes.ClprConnectorNotFound.selector);
        service.getConnector(channelId, hex"DEADBEEF");
    }

    function test_view_pendingCommitments_trackedAfterRegister() public {
        bytes32 c = keccak256(abi.encodePacked("fresh-commitment"));
        service.registerChannel(keccak256(abi.encodePacked("new-conn")), c);
        assertTrue(service.pendingCommitments(c));
        assertFalse(service.pendingCommitments(keccak256(abi.encodePacked("never-set"))));
    }

    function test_view_getLedgerConfiguration_returnsConfigured() public {
        ClprTypes.LedgerConfiguration memory cfg = service.getLedgerConfiguration();
        assertEq(cfg.serviceAddress, hex"1234");
        assertEq(cfg.throttles.maxQueueDepth, 1000);
        assertEq(cfg.throttles.maxMessagesPerBundle, 100);
    }

    function test_view_endpointCount_isOneAfterRegister() public {
        assertEq(service.endpointCount(), 1);
    }

    function test_view_pendingWithdrawals_zeroByDefault() public {
        assertEq(service.pendingWithdrawals(makeAddr("nobody")), 0);
    }

    function test_view_getEndpointEntry_status() public {
        assertEq(uint256(service.getEndpointEntry(owner).status), uint256(ClprTypes.EndpointStatus.LIVE));
        assertEq(
            uint256(service.getEndpointEntry(makeAddr("randomEoa")).status), uint256(ClprTypes.EndpointStatus.NONE)
        );
    }

    function test_view_getEndpointManifest_returnsLive() public {
        ClprTypes.ClprEndpointManifest memory m = service.getEndpointManifest();
        assertEq(m.endpoints.length, 1);
        assertEq(m.endpoints[0].accountId, hex"01");
        assertGe(m.version, 2); // seeded at 1, +1 on the addEndpoint above
    }

    function test_view_hasConnector_falseForUnknown() public {
        assertTrue(service.hasConnector(channelId, connectorId));
        assertFalse(service.hasConnector(channelId, hex"DEADBEEF"));
    }

    /// @dev Drives ClprService._staticDelegate (STATICCALL path), unique to deriveConnectorId.
    function test_view_deriveConnectorId_pure() public {
        bytes32 derived = service.deriveConnectorId(channelId, _signerPubKey(), bytes32(0));
        assertTrue(derived != bytes32(0));
    }

    function test_view_getMessage_emptyForUnsentId() public {
        ClprTypes.MessageValue memory msg_ = service.getMessage(channelId, 99);
        assertEq(msg_.payload.length, 0);
    }

    function test_view_getQueueDepth_zeroForFreshChannel() public {
        ClprTypes.QueueDepth memory qd = service.getQueueDepth(channelId);
        assertEq(qd.queueDepth, 0);
        assertEq(qd.maxQueueDepth, 1000);
    }

    function test_view_getQueueDepth_revertsIfMissing() public {
        vm.expectRevert(ClprTypes.ClprChannelNotFound.selector);
        service.getQueueDepth(keccak256(abi.encodePacked("does-not-exist")));
    }

    receive() external payable {}
}
