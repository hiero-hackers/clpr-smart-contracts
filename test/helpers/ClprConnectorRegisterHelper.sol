// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IClprService} from "@hiero-ledger/clpr/interfaces/IClprService.sol";
import {ConnectorRegistrar} from "@test/helpers/ConnectorRegistrar.sol";

/// @notice Thin external wrapper so `ClprHandler` can try/catch connector registration without exposing a fuzz target.
contract ClprConnectorRegisterHelper {
    function register(
        IClprService service,
        bytes32 channelId,
        bytes32 seed,
        address connector,
        address admin,
        uint256 stake
    ) external returns (bytes32 connectorId) {
        return ConnectorRegistrar.register(service, channelId, seed, connector, admin, stake);
    }
}
