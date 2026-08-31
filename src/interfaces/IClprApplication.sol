// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IClprApplication
/// @notice Interface for application contracts that send/receive cross-ledger messages.
interface IClprApplication {
    /// @notice Called when a cross-ledger data message arrives.
    /// @param channelId The channel the message arrived on
    /// @param sender The sender address on the peer chain (opaque bytes)
    /// @param messageData The message payload
    /// @return responseData Response data to send back to the peer
    function onClprMessage(bytes32 channelId, bytes calldata sender, bytes calldata messageData)
        external
        returns (bytes memory responseData);

    /// @notice Called (best-effort) when a response to a previously sent message arrives.
    /// @dev Reverts are caught and ignored — this is a notification, not a guarantee.
    /// @param channelId The channel the response arrived on
    /// @param messageId The original outbound message ID this responds to
    /// @param status The reply status code (cast from ClprTypes.ReplyStatus)
    /// @param responseData The response payload
    function onClprResponse(bytes32 channelId, uint64 messageId, uint8 status, bytes calldata responseData) external;
}
