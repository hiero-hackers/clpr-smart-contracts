// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ClprService} from "@hiero-ledger/clpr/ClprService.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprConfigHash} from "@hiero-ledger/clpr/libraries/codec/ClprConfigHash.sol";
import {MockClprVerifier} from "@test/mocks/MockClprVerifier.sol";
import {ClprTestBase} from "@test/helpers/ClprTestBase.sol";

contract ConfigHashTest is ClprTestBase {
    uint256 internal connSignerPk = uint256(keccak256("config-hash-signer"));

    bytes internal constant TEST_ANCHOR = hex"DEADBEEF";
    bytes internal constant TEST_ANCHOR_ID = hex"01";

    function setUp() public override {
        service = _deployClprService(1, "eip155:1337");

        verifier = new MockClprVerifier();
        verifier.setVerifyConfigResult("eip155:1", hex"AABB", 1000);
        verifier.setPeerThrottles(_defaultThrottles());
        verifier.setInitialTrustAnchor(TEST_ANCHOR);
        verifier.setInitialTrustAnchorId(TEST_ANCHOR_ID);

        ClprTypes.Endpoint[] memory seeds = new ClprTypes.Endpoint[](1);
        seeds[0] = _peerEndpointSeedEntry();
        verifier.setSeedEndpoints(seeds);

        _initializeAndEnable();
        _createActiveChannel();
    }

    // ── getLedgerConfigurationHash ─────────────────────────────────────────

    function test_ledgerHash_matchesOffchainRecompute() public {
        ClprTypes.LedgerConfiguration memory cfg = service.getLedgerConfiguration();
        bytes32 expected = keccak256(
            abi.encode(
                cfg.protocolVersion,
                cfg.chainId,
                cfg.serviceAddress,
                cfg.nanosSinceEpoch,
                cfg.throttles,
                cfg.trustAnchor,
                cfg.trustAnchorId
            )
        );
        assertEq(service.getLedgerConfigurationHash(), expected);
    }

    /// @dev Sanity check: the field-list encoding differs from the whole-struct
    ///      encoding by exactly the 32-byte outer offset pointer. Documents the
    ///      cross-language reasoning behind preferring field-list form.
    function test_ledgerHash_fieldListDiffersFromStructEncoding() public {
        ClprTypes.LedgerConfiguration memory cfg = service.getLedgerConfiguration();
        bytes32 structForm = keccak256(abi.encode(cfg));
        bytes32 fieldForm = service.getLedgerConfigurationHash();
        assertTrue(structForm != fieldForm, "field-list and struct encodings must differ");
    }

    function test_ledgerHash_isStableAcrossReads() public {
        bytes32 h1 = service.getLedgerConfigurationHash();
        bytes32 h2 = service.getLedgerConfigurationHash();
        assertEq(h1, h2);
    }

    function test_ledgerHash_changesWhenTrustAnchorAdded() public {
        bytes32 before = service.getLedgerConfigurationHash();
        // Advance time so nanosSinceEpoch differs (also a hash input). The check
        // below would still pass without this — trustAnchor alone changes the
        // digest — but bumping the timestamp matches real admin-update behavior.
        vm.warp(block.timestamp + 1);
        service.updateLedgerConfiguration(hex"1234", _defaultThrottles(), hex"AA", hex"BB");
        bytes32 afterUpdate = service.getLedgerConfigurationHash();
        assertTrue(before != afterUpdate, "hash must change when trustAnchor is set");
    }

    // NOTE: test_ledgerHash_changesWhenSeedEndpointsChange removed — endpoints are no longer part of
    // LedgerConfiguration or its hash (ADR: endpoint manifests are separate CLPR Service state).

    // ── getChannelPeerConfigHash ────────────────────────────────────────

    function test_peerConfigHash_matchesPureHelper() public {
        ClprTypes.Channel memory c = service.getChannel(channelId);
        bytes32 expected = ClprConfigHash.hashChannelPeerConfig(
            c.chainId, c.peerServiceAddress, c.peerConfigTimestamp, c.peerThrottles, c.trustAnchor, c.trustAnchorId
        );
        assertEq(service.getChannelPeerConfigHash(channelId), expected);
    }

    function test_peerConfigHash_includesTrustAnchor() public {
        ClprTypes.Channel memory c = service.getChannel(channelId);
        bytes32 withAnchor = ClprConfigHash.hashChannelPeerConfig(
            c.chainId, c.peerServiceAddress, c.peerConfigTimestamp, c.peerThrottles, c.trustAnchor, c.trustAnchorId
        );
        bytes32 withoutAnchor = ClprConfigHash.hashChannelPeerConfig(
            c.chainId, c.peerServiceAddress, c.peerConfigTimestamp, c.peerThrottles, "", c.trustAnchorId
        );
        assertTrue(withAnchor != withoutAnchor, "hash must depend on trustAnchor");
    }

    function test_peerConfigHash_includesTrustAnchorId() public {
        ClprTypes.Channel memory c = service.getChannel(channelId);
        bytes32 withId = ClprConfigHash.hashChannelPeerConfig(
            c.chainId, c.peerServiceAddress, c.peerConfigTimestamp, c.peerThrottles, c.trustAnchor, c.trustAnchorId
        );
        bytes32 withoutId = ClprConfigHash.hashChannelPeerConfig(
            c.chainId, c.peerServiceAddress, c.peerConfigTimestamp, c.peerThrottles, c.trustAnchor, ""
        );
        assertTrue(withId != withoutId, "hash must depend on trustAnchorId");
    }

    function test_peerConfigHash_revertsForUnknownChannel() public {
        vm.expectRevert(ClprTypes.ClprChannelNotFound.selector);
        service.getChannelPeerConfigHash(bytes32(uint256(0xBAD)));
    }
}
