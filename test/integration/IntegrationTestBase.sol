// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ClprService} from "@hiero-ledger/clpr/ClprService.sol";
import {IClprService} from "@hiero-ledger/clpr/interfaces/IClprService.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {MockClprApplication} from "@test/mocks/MockClprApplication.sol";
import {MockClprConnector} from "@test/mocks/MockClprConnector.sol";
import {ConnectorRegistrar} from "@test/helpers/ConnectorRegistrar.sol";
import {ClprTestBase} from "@test/helpers/ClprTestBase.sol";

/// @dev Abstract base for integration/lifecycle tests against a concrete IClprVerifier.
///      Each verifier (MockClprVerifier, QBFTVerifier, HieroVerifier) gets its own
///      concrete test file that deploys the verifier and wires it into the service.
abstract contract IntegrationTestBase is ClprTestBase {
    uint256 internal constant SIGNER_PK = 0xC0DE;
    MockClprApplication internal app;
    bytes32 internal connectorAddr;

    // ── Peer endpoint config ──────────────────────────────────────────
    string internal constant PEER_CHAIN_ID = "eip155:1";
    uint96 internal constant PEER_CONFIG_NANOS = 1000;
    uint256 internal constant MESSAGE_EXECUTION_COST = 0.001 ether;
    uint256 internal constant ENDPOINT_MARGIN_PCT = 10;
    uint256 internal constant MIN_LOCKED_STAKE = 0.1 ether;

    // ── Deploy service + wire the verifier ────────────────────────────
    // Child contracts set _verifier by deploying their specific verifier type.

    function _deployServiceAndConnect(address verifier_) internal {
        signerPk = SIGNER_PK;
        signer = vm.addr(SIGNER_PK);

        service = _deployClprService(1, "eip155:1337");

        // Deploy app and connector
        app = new MockClprApplication();
        app.setResponse(hex"504F4E47"); // "PONG"
        connector = new MockClprConnector();

        _initializeAndEnable();

        _deployAndConnectVerifier(verifier_);

        // Register caller as an endpoint so submitBundle is authorized.
        bytes memory key = new bytes(64);
        key[0] = 0x01;
    }

    function _deployAndConnectVerifier(address verifier_) internal virtual {
        bytes memory pubKey = _signerPubKey();
        channelId = _deriveTestChannelId(pubKey, bytes32(0));
        bytes32 commitment = keccak256(abi.encodePacked(channelId, pubKey));
        service.registerChannel(channelId, commitment);

        bytes32 msgHash = keccak256(abi.encodePacked(channelId, address(service)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, _ethSignedHash(msgHash));
        service.completeChannel(channelId, pubKey, abi.encodePacked(r, s, v), bytes32(0), verifier_, hex"0001", "");
    }

    // ── Lifecycle helper: register connector, send outbound ───────────
    function _registerConnectorAndSend() internal returns (uint64) {
        connectorAddr = ConnectorRegistrar.register(
            IClprService(address(service)),
            channelId,
            // forge-lint: disable-next-line(unsafe-typecast) — short ASCII connector id fits in bytes32.
            bytes32("integration-connector"),
            address(connector),
            owner,
            1 ether
        );
        (bool ok,) = address(connector).call{value: 9 ether}("");
        require(ok, "fund connector failed");

        vm.prank(address(app));
        return service.sendMessage(channelId, connectorAddr, abi.encodePacked(address(app)), hex"48454C4C4F");
    }

    // ── Lifecycle helper: verify post-bundle state ────────────────────

    /// @dev Full lifecycle check. Default: expects the bundle to contain both a DATA
    ///      message (delivered to the local app) AND a REPLY from the peer acking our
    ///      outbound message. Use the overload with `expectedResponseCount = 0` when
    ///      the bundle carries only DATA (e.g., QBFT tests where Besu can't emit a
    ///      peer-side REPLY without a real round-trip).
    function _verifyPostBundle(
        uint64 expectedOutboundMsgId,
        uint64 expectedNextMsgId,
        bytes memory inboundMsgPayload,
        uint64 replyMsgId,
        uint64 expectedReceivedMsgId,
        uint64 expectedAckedMsgId,
        ClprTypes.ChannelStatus expectedStatus
    ) internal {
        _verifyPostBundle(
            expectedOutboundMsgId,
            expectedNextMsgId,
            inboundMsgPayload,
            replyMsgId,
            expectedReceivedMsgId,
            expectedAckedMsgId,
            expectedStatus,
            1
        );
    }

    function _verifyPostBundle(
        uint64 expectedOutboundMsgId,
        uint64 expectedNextMsgId,
        bytes memory inboundMsgPayload,
        uint64 replyMsgId,
        uint64 expectedReceivedMsgId,
        uint64 expectedAckedMsgId,
        ClprTypes.ChannelStatus expectedStatus,
        uint256 expectedResponseCount
    ) internal {
        // App was called with inbound DATA
        assertEq(app.getMessageCallCount(), 1, "App should have been called once");
        (,, bytes memory receivedPayload) = app.messageCalls(0);
        assertEq(receivedPayload, inboundMsgPayload, "Inbound payload mismatch");

        if (expectedResponseCount > 0) {
            // App received response callback for our outbound (requires REPLY from peer)
            assertEq(app.getResponseCallCount(), expectedResponseCount, "App response callback count mismatch");
            (bytes32 respConnId, uint64 respMsgId, uint8 respStatus,) = app.responseCalls(0);
            assertEq(respConnId, channelId, "Response channel ID mismatch");
            assertEq(respMsgId, expectedOutboundMsgId, "Response should be for the right message");
            assertEq(respStatus, uint8(ClprTypes.ReplyStatus.SUCCESS), "Response status should be SUCCESS");

            // Outbound message deleted after reply processed
            ClprTypes.MessageValue memory deletedMsg = service.getMessage(channelId, expectedOutboundMsgId);
            assertEq(deletedMsg.payload.length, 0, "Outbound message should have been deleted after reply");
        }

        // Reply was queued for the inbound DATA
        ClprTypes.MessageValue memory replyMsg = service.getMessage(channelId, replyMsgId);
        assertTrue(replyMsg.payload.length > 0, "Reply to inbound DATA should be queued");
        ClprTypes.DecodedReply memory decodedReply = ClprProtobuf.decodeReplyMessage(replyMsg.payload);
        assertEq(decodedReply.messageId, expectedOutboundMsgId, "Reply should be to the right message");
        assertEq(uint8(decodedReply.status), uint8(ClprTypes.ReplyStatus.SUCCESS), "Reply status should be SUCCESS");

        // Channel state
        ClprTypes.Channel memory channel = service.getChannel(channelId);
        assertEq(channel.receivedMessageId, expectedReceivedMsgId, "receivedMessageId");
        assertEq(channel.ackedMessageId, expectedAckedMsgId, "ackedMessageId");
        assertEq(channel.nextMessageId, expectedNextMsgId, "nextMessageId");
        assertEq(uint8(channel.status), uint8(expectedStatus), "Channel status");
    }

    function _closeChannel() internal {
        service.closeChannel(channelId);
        assertEq(
            uint8(service.getChannel(channelId).status),
            uint8(ClprTypes.ChannelStatus.CLOSING),
            "Channel should be CLOSING"
        );
    }

    function _buildInboundBundles(uint64 replyToMsgId) internal view returns (bytes[] memory) {
        bytes[] memory inboundMsgs = new bytes[](2);
        inboundMsgs[0] = ClprProtobuf.encodeDataMessage(
            connectorAddr, abi.encodePacked(address(app)), hex"BEEF0102", hex"48454C4C4F"
        );
        inboundMsgs[1] =
            ClprProtobuf.encodeReplyMessage(replyToMsgId, ClprTypes.ReplyStatus.SUCCESS, hex"504F4E47524550");
        return inboundMsgs;
    }

    // ── Cross-channel isolation ─────────────────────────────────────
    // A storage proof keyed to channel B must be rejected when submitted for
    // channel A. Override in each real-verifier integration suite to exercise
    // this invariant with a proof signed by the actual verifier's validator.
    function test_rejectBundle_storageProofForWrongChannel() public virtual {}

    receive() external payable {}
}
