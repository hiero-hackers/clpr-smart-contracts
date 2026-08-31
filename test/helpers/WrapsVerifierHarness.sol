// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {WRAPSVerifier} from "@hiero-ledger/clpr/verifiers/hiero/wraps/WRAPSVerifier.sol";

/// @dev Thin contract that exposes WRAPSVerifier.verify for testing.
contract WRAPSVerifierHarness {
    function verify(bytes calldata abProof, bytes calldata hintsVk, bytes calldata ledgerId, address poseidon)
        external
        view
        returns (bool)
    {
        return WRAPSVerifier.verify(abProof, hintsVk, ledgerId, poseidon);
    }
}
