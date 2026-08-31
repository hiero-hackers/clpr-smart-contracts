// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ClprService} from "@hiero-ledger/clpr/ClprService.sol";

/// @notice Rejects direct ETH transfers; accumulates pull-payment credits via `collectPending`.
contract EthRejector {
    receive() external payable {
        revert("EthRejector: no receive");
    }

    function collect(ClprService service) external {
        service.collectPending();
    }

    /// @notice Used by invariant tests so slash/charge fallback (service owner) also rejects ETH.
    function transferServiceOwnership(ClprService service, address newOwner) external {
        service.transferOwnership(newOwner);
    }
}
