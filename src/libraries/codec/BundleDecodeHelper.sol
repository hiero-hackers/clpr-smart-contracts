// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";

/// @title BundleDecodeHelper
/// @notice Thin external contract that exposes ClprProtobuf decode functions so that
///         BundleLib can use try/catch around them to isolate decode failures.
/// @dev Deployed once; address stored as immutable on ClprService. BundleLib receives
///      the address via processBundle and uses it as the try/catch target. All functions
///      are pure/view — no state is read or written.
contract BundleDecodeHelper {
    /// @notice Decode a DATA message payload. Reverts on malformed input.
    function decodeData(bytes calldata payload) external pure returns (ClprTypes.DecodedDataMessage memory) {
        return ClprProtobuf.decodeDataMessage(payload);
    }

    /// @notice Decode a REPLY message payload. Reverts on malformed input.
    function decodeReply(bytes calldata payload) external pure returns (ClprTypes.DecodedReply memory) {
        return ClprProtobuf.decodeReplyMessage(payload);
    }

    /// @notice Decode a CONTROL message payload. Reverts on malformed input.
    function decodeControl(bytes calldata payload) external pure returns (ClprTypes.DecodedControl memory) {
        return ClprProtobuf.decodeControlMessage(payload);
    }
}
