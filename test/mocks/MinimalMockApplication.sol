// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprApplication} from "@hiero-ledger/clpr/interfaces/IClprApplication.sol";

/// @notice Minimal mock application for gas benchmarking - no storage writes.
contract MinimalMockApplication is IClprApplication {
    bytes private _responseData;

    function setResponse(bytes memory responseData) external {
        _responseData = responseData;
    }

    function onClprMessage(bytes32, bytes calldata, bytes calldata) external view override returns (bytes memory) {
        return _responseData;
    }

    function onClprResponse(bytes32, uint64, uint8, bytes calldata) external pure override {
        // No-op for gas benchmarking
    }
}
