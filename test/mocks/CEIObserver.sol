// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IClprService} from "@hiero-ledger/clpr/interfaces/IClprService.sol";

/// @notice Observer used to validate Checks-Effects-Interactions pattern.
/// When it receives ETH from ClprService.removeConnector, it immediately
/// queries the service to check whether the connector has already been
/// removed. If state was updated before the external call, `hasConnector`
/// will return false and `observedRemoved` will be set to true.
contract CEIObserver {
    IClprService public immutable service;
    bytes32 public immutable channelId;
    bytes32 public connectorId;

    bool public observedRemoved; // true if service.hasConnector(...) returned false in receive()

    event Observed(bool removed);

    constructor(IClprService _service, bytes32 _channelId, bytes32 _connectorId) {
        service = _service;
        channelId = _channelId;
        connectorId = _connectorId;
    }

    receive() external payable {
        // Only a read-only query; does not attempt to reenter state-modifying functions.
        bool exists = service.hasConnector(channelId, connectorId);
        observedRemoved = !exists;
        emit Observed(observedRemoved);
    }
}
