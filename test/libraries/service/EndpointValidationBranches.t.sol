// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprTypes} from "../../../src/libraries/ClprTypes.sol";
import {EndpointValidationHarness, DerCertBuilder} from "./EndpointValidation.t.sol";

/// @notice EndpointValidation's IP edge cases and DER-corruption paths.
contract EndpointValidationBranchesTest is Test, DerCertBuilder {
    EndpointValidationHarness internal harness;

    function setUp() public {
        harness = new EndpointValidationHarness();
    }
}
