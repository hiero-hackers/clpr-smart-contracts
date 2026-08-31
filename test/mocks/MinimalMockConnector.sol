// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprConnector} from "@hiero-ledger/clpr/interfaces/IClprConnector.sol";

/// @notice Minimal mock connector for gas benchmarking - no storage writes.
contract MinimalMockConnector is IClprConnector {
    function authorizeOutboundMessage(bytes32, bytes calldata, bytes calldata, bytes calldata)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function payForExecution(uint256 amount) external override {
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay transfer failed");
    }

    function onInboundMessage(bytes32, uint64, bytes calldata, bytes calldata, bytes calldata) external pure override {
        // No-op for gas benchmarking
    }

    receive() external payable {}
}
