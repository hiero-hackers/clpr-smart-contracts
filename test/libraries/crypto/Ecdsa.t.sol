// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprTypes} from "../../../src/libraries/ClprTypes.sol";
import {ECDSA} from "../../../src/libraries/crypto/ECDSA.sol";

contract EcdsaHarness {
    function verifySignature(bytes32 channelId, bytes calldata pubKey, bytes calldata sig) external view {
        ECDSA._verifySignature(channelId, pubKey, sig);
    }
}

/// @notice The library's own pubKey-length guard
contract EcdsaTest is Test {
    EcdsaHarness internal harness;

    function setUp() public {
        harness = new EcdsaHarness();
    }

    function test_verifySignature_wrongPubKeyLength_reverts() public {
        vm.expectRevert(ClprTypes.ClprInvalidSignature.selector);
        harness.verifySignature(bytes32(0), new bytes(63), new bytes(65));
    }
}
