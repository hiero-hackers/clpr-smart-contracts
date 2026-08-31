// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprBls12381} from "@hiero-ledger/clpr/libraries/proof/beacon/ClprBls12381.sol";

/// @dev Validates the hand-rolled BLS12-381 compression against the published curve generators —
///      the authoritative correctness check for the field arithmetic and sign conventions.
contract ClprBls12381Test is Test {
    // BLS12-381 G1 generator, ZCash/Ethereum serialization.
    bytes internal constant G1_GEN_COMPRESSED =
        hex"97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal constant G1_GEN_X =
        hex"17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes internal constant G1_GEN_Y =
        hex"08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";

    /// @dev Compressing the uncompressed generator must reproduce the canonical compressed generator
    ///      (validates x-copy, the sign bit, and flags). On-chain decompression is not implemented —
    ///      the relayer supplies uncompressed points — so only the compress direction is exercised.
    function test_compressG1_generator() public pure {
        bytes memory uncompressed = abi.encodePacked(bytes16(0), G1_GEN_X, bytes16(0), G1_GEN_Y);
        bytes memory got = ClprBls12381.compressG1(uncompressed);
        assertEq(got.length, 48, "compressed G1 is 48 bytes");
        assertEq(keccak256(got), keccak256(G1_GEN_COMPRESSED), "compressed G1 generator mismatch");
    }

    function test_compressG1_infinity() public pure {
        bytes memory got = ClprBls12381.compressG1(new bytes(128));
        bytes memory expected = new bytes(48);
        expected[0] = bytes1(uint8(0xc0)); // compressed + infinity
        assertEq(keccak256(got), keccak256(expected), "infinity -> 0xc0 prefix");
    }
}
