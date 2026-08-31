// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprApplication} from "@hiero-ledger/clpr/interfaces/IClprApplication.sol";
import {IClprService} from "@hiero-ledger/clpr/interfaces/IClprService.sol";

/// @title E2EApplication
/// @notice Test-only application contract used by the two-chain end-to-end suite
///         as BOTH a source-side caller (it calls `service.sendMessage(...)`,
///         which means the on-chain `sender` field of the outbound DATA gets
///         stamped as **this contract's address**, not an EOA) AND a
///         destination-side receiver (it implements `IClprApplication` so
///         inbound `onClprMessage` / `onClprResponse` callbacks land here).
///
/// @dev Needed because if an EOA calls `service.sendMessage`, the `sender`
///      bytes stamped into the outbound DATA point at an EOA. When the REPLY
///      arrives on the source chain, `BundleLib._processReplyMessageDecoded`
///      attempts a callback to that sender address — but only if the address
///      has code (see [src/libraries/service/BundleLib.sol:847](src/libraries/service/BundleLib.sol#L847)).
///      EOAs are skipped, so the response side of the roundtrip is unobservable.
///      Routing the send through this contract makes the callback reachable.
///
///      Combines the two halves of the legacy `test/mocks/MockClprApplication.sol`
///      (which is still kept around for Foundry unit tests) with a single
///      `send()` wrapper.
contract E2EApplication is IClprApplication {
    struct MessageCall {
        bytes32 channelId;
        bytes sender;
        bytes messageData;
    }

    struct ResponseCall {
        bytes32 channelId;
        uint64 messageId;
        uint8 status;
        bytes responseData;
    }

    MessageCall[] public messageCalls;
    ResponseCall[] public responseCalls;

    bytes private _responseData;
    bool private _messageShouldRevert;
    bool private _responseShouldRevert;

    // ── Sender wrapper ─────────────────────────────────────────────────────

    /// Call `service.sendMessage` from this contract's address so that the
    /// `sender` bytes stamped into the outbound DATA payload equal
    /// `address(this)`. Returns the assigned outbound `messageId`.
    function send(
        IClprService service,
        bytes32 channelId,
        bytes32 connectorId,
        bytes calldata targetApplication,
        bytes calldata messageData
    ) external returns (uint64) {
        return service.sendMessage(channelId, connectorId, targetApplication, messageData);
    }

    // ── Inbound recorders ──────────────────────────────────────────────────

    function setResponse(bytes calldata responseData) external {
        _responseData = responseData;
    }

    function setMessageShouldRevert(bool shouldRevert) external {
        _messageShouldRevert = shouldRevert;
    }

    function setResponseShouldRevert(bool shouldRevert) external {
        _responseShouldRevert = shouldRevert;
    }

    function getMessageCallCount() external view returns (uint256) {
        return messageCalls.length;
    }

    function getResponseCallCount() external view returns (uint256) {
        return responseCalls.length;
    }

    function onClprMessage(bytes32 channelId, bytes calldata sender, bytes calldata messageData)
        external
        override
        returns (bytes memory)
    {
        if (_messageShouldRevert) revert("E2EApplication: configured revert");
        messageCalls.push(MessageCall({channelId: channelId, sender: sender, messageData: messageData}));
        return _responseData;
    }

    function onClprResponse(bytes32 channelId, uint64 messageId, uint8 status, bytes calldata responseData)
        external
        override
    {
        if (_responseShouldRevert) revert("E2EApplication: configured response revert");
        responseCalls.push(
            ResponseCall({channelId: channelId, messageId: messageId, status: status, responseData: responseData})
        );
    }
}
