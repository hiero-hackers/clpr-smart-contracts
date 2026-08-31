// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";

/// @notice Drop-in replacement for BundleDecodeHelper that lets individual payloads
///         be marked as failing decode. Used to exercise the §4.2 Step 6 "continue
///         on per-message failure" paths in _dispatchMessages without requiring
///         hand-crafted malformed protobuf for every message type.
contract MockBundleDecodeHelper {
    mapping(bytes32 => bool) private _failData;
    mapping(bytes32 => bool) private _failReply;
    mapping(bytes32 => bool) private _failControl;

    function setDataDecodeFails(bytes calldata payload) external {
        _failData[keccak256(payload)] = true;
    }

    function setReplyDecodeFails(bytes calldata payload) external {
        _failReply[keccak256(payload)] = true;
    }

    function setControlDecodeFails(bytes calldata payload) external {
        _failControl[keccak256(payload)] = true;
    }

    function decodeData(bytes calldata payload) external view returns (ClprTypes.DecodedDataMessage memory) {
        if (_failData[keccak256(payload)]) revert("mock: DATA decode failed");
        return ClprProtobuf.decodeDataMessage(payload);
    }

    function decodeReply(bytes calldata payload) external view returns (ClprTypes.DecodedReply memory) {
        if (_failReply[keccak256(payload)]) revert("mock: REPLY decode failed");
        return ClprProtobuf.decodeReplyMessage(payload);
    }

    function decodeControl(bytes calldata payload) external view returns (ClprTypes.DecodedControl memory) {
        if (_failControl[keccak256(payload)]) revert("mock: CONTROL decode failed");
        return ClprProtobuf.decodeControlMessage(payload);
    }
}
