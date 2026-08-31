// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title BundleEncoderHelper
/// @notice Test-only helper exposing ClprProtobuf.encodeBundleContent as an
///         external pure function so off-chain code (the E2E relay) can ask
///         the chain to produce the canonical `ClprBundleContent` protobuf
///         bytes via `eth_call`. This avoids reimplementing the protobuf
///         encoder in TypeScript and keeps the wire format authoritative on
///         the Solidity side.
/// @dev Internal library functions cannot be reached from off-chain calls;
///      wrapping them in a thin external function makes them callable.
contract BundleEncoderHelper {
    function encode(ClprTypes.QueueMetadata calldata metadata, bytes[] calldata messagePayloads)
        external
        pure
        returns (bytes memory)
    {
        return ClprProtobuf.encodeBundleContent(metadata, messagePayloads);
    }
}
