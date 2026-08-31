// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprApplication} from "@hiero-ledger/clpr/interfaces/IClprApplication.sol";

contract MockClprApplication is IClprApplication {
    error InvalidAmount(uint256 requested, uint256 available);

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
    bool private _shouldRevert;
    string private _revertReason;
    bool private _shouldThrowCustomError;
    uint256 private _customErrorRequested;
    uint256 private _customErrorAvailable;
    bool private _responseShouldRevert;
    string private _responseRevertReason;

    function setResponse(bytes memory responseData) external {
        _responseData = responseData;
    }

    function setShouldRevert(bool shouldRevert, string memory reason) external {
        _shouldRevert = shouldRevert;
        _revertReason = reason;
    }

    function setShouldThrowCustomError(bool shouldThrow, uint256 requested, uint256 available) external {
        _shouldThrowCustomError = shouldThrow;
        _customErrorRequested = requested;
        _customErrorAvailable = available;
    }

    function setResponseShouldRevert(bool shouldRevert, string memory reason) external {
        _responseShouldRevert = shouldRevert;
        _responseRevertReason = reason;
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
        if (_shouldRevert) revert(_revertReason);
        if (_shouldThrowCustomError) revert InvalidAmount(_customErrorRequested, _customErrorAvailable);
        messageCalls.push(MessageCall({channelId: channelId, sender: sender, messageData: messageData}));
        return _responseData;
    }

    function onClprResponse(bytes32 channelId, uint64 messageId, uint8 status, bytes calldata responseData)
        external
        override
    {
        if (_responseShouldRevert) revert(_responseRevertReason);
        responseCalls.push(
            ResponseCall({channelId: channelId, messageId: messageId, status: status, responseData: responseData})
        );
    }
}
