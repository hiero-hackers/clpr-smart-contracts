// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ed25519Verifier} from "@hiero-ledger/clpr/verifiers/evm/sei/Ed25519Verifier.sol";
import {IEd25519Verifier} from "@hiero-ledger/clpr/verifiers/evm/sei/lib/IEd25519Verifier.sol";

/// Validates the vendored/ported (0.6.8 -> 0.8) pure-Solidity Ed25519, called externally via the
/// deployed Ed25519Verifier, against RFC 8032 §7.1 TEST 2 (1-byte message).
contract Ed25519PortTest is Test {
    IEd25519Verifier verifier;

    // RFC 8032 TEST 2
    bytes32 constant PUB = 0x3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c;
    bytes constant SIG =
        hex"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00";
    bytes constant MSG = hex"72";

    function setUp() public {
        verifier = new Ed25519Verifier();
    }

    function test_rfc8032_test2_validSignature_returnsTrue() public view {
        assertTrue(verifier.verify(PUB, MSG, SIG), "valid RFC8032 sig must verify");
    }

    function test_tamperedMessage_returnsFalse() public view {
        assertFalse(verifier.verify(PUB, hex"73", SIG), "tampered message must fail");
    }

    function test_tamperedSignature_returnsFalse() public view {
        bytes memory bad = bytes.concat(SIG);
        bad[63] ^= 0x01;
        assertFalse(verifier.verify(PUB, MSG, bad), "tampered signature must fail");
    }

    function test_wrongLengthSignature_returnsFalse() public view {
        assertFalse(verifier.verify(PUB, MSG, hex"1234"), "non-64-byte sig must fail");
    }

    function test_sOutOfRange_returnsFalse() public view {
        // Valid R bytes from TEST 2, but s = all 0xff.
        // After LE→BE reversal: uint256(s) = 2^256 − 1 >> group order L → returns false.
        bytes memory sig = abi.encodePacked(
            bytes32(0x92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da),
            bytes32(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
        );
        assertFalse(verifier.verify(PUB, MSG, sig), "s >= group order must return false");
    }
}
