// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {TSSVerifier} from "@hiero-ledger/clpr/verifiers/hiero/TSSVerifier.sol";

/// @dev Exposes TSSVerifier._verifyHintsAggregate for unit testing.
contract TSSVerifierHarness is TSSVerifier {
    constructor() TSSVerifier(address(0)) {}

    function verifyHintsAggregate(bytes calldata hintVk, bytes calldata hintSig, bytes calldata blockRootHash)
        external
        view
        returns (bool)
    {
        return _verifyHintsAggregate(hintVk, hintSig, blockRootHash);
    }
}
