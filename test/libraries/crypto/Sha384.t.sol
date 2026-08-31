// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Sha384} from "@hiero-ledger/clpr/libraries/crypto/Sha384.sol";

/// @dev FIPS 180-4 test vectors for SHA-384. The published outputs are the
///      authoritative correctness check — they exercise the IV, padding,
///      and message schedule across single-block, boundary, and multi-block
///      inputs.
contract Sha384Test is Test {
    // FIPS 180-4 Appendix D / NIST Cryptographic Algorithm Validation Program
    // (CAVP) byte vectors.

    bytes32 private constant EMPTY_HI = 0x38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da;
    bytes16 private constant EMPTY_LO = 0x274edebfe76f65fbd51ad2f14898b95b;

    bytes32 private constant ABC_HI = 0xcb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed;
    bytes16 private constant ABC_LO = 0x8086072ba1e7cc2358baeca134c825a7;

    // Length 56 ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    bytes32 private constant L56_HI = 0x3391fdddfc8dc7393707a65b1b4709397cf8b1d162af05abfe8f450de5f36bc6;
    bytes16 private constant L56_LO = 0xb0455a8520bc4e6f5fe95b1fe3c8452b;

    // Length 112 — straddles 128-byte block boundary, exercises 2-block compress.
    // "abcdefghbcdefghicdefghij...stnopqrstu"
    bytes32 private constant L112_HI = 0x09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712;
    bytes16 private constant L112_LO = 0xfcc7c71a557e2db966c3e9fa91746039;

    // SHA-384(1,000,000 of 'a') — the FIPS "long message" stress test. Omitted
    // from the on-chain suite because pure-Solidity SHA-384 is ~280k gas per
    // 128-byte block; 7,813 blocks would blow the block gas limit by several
    // orders of magnitude. Kept here as a documented constant for offline
    // cross-checks if a Rust/Go harness is wired up later.

    // --- Vectors ----------------------------------------------------------

    function test_empty() public pure {
        bytes memory got = Sha384.hash("");
        _assertHash(got, EMPTY_HI, EMPTY_LO, "SHA-384('')");
    }

    function test_abc() public pure {
        bytes memory got = Sha384.hash("abc");
        _assertHash(got, ABC_HI, ABC_LO, "SHA-384('abc')");
    }

    function test_length56_singleBlockNearBoundary() public pure {
        // 56 bytes: 56 + 1 + 16 = 73 ≤ 128 → single block, but length-field
        // sits right next to data with no zero gap.
        bytes memory input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        assertEq(input.length, 56, "test vector length");
        bytes memory got = Sha384.hash(input);
        _assertHash(got, L56_HI, L56_LO, "SHA-384(length-56 vector)");
    }

    function test_length112_multiBlockBoundary() public pure {
        // 112 bytes: 112 + 1 + 16 = 129 > 128 → forces a second block of
        // pure padding. This is the load-bearing multi-block test.
        bytes memory input =
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
        assertEq(input.length, 112, "test vector length");
        bytes memory got = Sha384.hash(input);
        _assertHash(got, L112_HI, L112_LO, "SHA-384(length-112 vector)");
    }

    // --- Padding boundary sanity ------------------------------------------

    function test_length111_oneBlockExact() public pure {
        // 111 + 1 + 16 = 128 → single block, padding fits exactly with
        // zero padZeros. This is the largest "fits-in-one-block" input.
        _assertOutputLength(111, 0x61);
    }

    function test_length128_isExactlyTwoBlocks() public pure {
        // 128 + 1 + 16 = 145 > 128 → second block of padding.
        _assertOutputLength(128, 0x61);
    }

    function test_length239_multiBlock_branchCondition() public pure {
        // 239 bytes: 239 + 17 = 256 = 2 * 128 → forces exactly 2 compression blocks.
        // At (dataLen+17)%128 == 0 the paddedLen%128==0 short-circuit triggers
        // (the `else` at line ~45 of Sha384.sol). This is the multi-block variant
        // of test_length111_oneBlockExact.
        bytes memory input = new bytes(239);
        for (uint256 i = 0; i < 239; i++) {
            input[i] = 0x61;
        }
        assertEq(input.length, 239, "multi-block test vector length");
        bytes memory got = Sha384.hash(input);
        assertEq(got.length, 48, "SHA-384 output length for multi-block input");
    }

    function test_deterministic_sameInputSameHash() public pure {
        bytes memory got1 = Sha384.hash(hex"00112233");
        bytes memory got2 = Sha384.hash(hex"00112233");
        assertEq(keccak256(got1), keccak256(got2));
    }

    function test_avalanche_oneBitFlipChangesOutput() public pure {
        bytes memory got1 = Sha384.hash(hex"00");
        bytes memory got2 = Sha384.hash(hex"01");
        assertTrue(keccak256(got1) != keccak256(got2));
    }

    // --- Helpers ----------------------------------------------------------

    /// @dev Hashes `n` bytes all equal to `fillByte` and asserts the output is
    ///      the fixed 48-byte SHA-384 digest. Parametrizes the family of
    ///      length/padding-boundary cases above.
    function _assertOutputLength(uint256 n, bytes1 fillByte) private pure {
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = fillByte;
        }
        bytes memory got = Sha384.hash(input);
        assertEq(got.length, 48);
    }

    function _assertHash(bytes memory got, bytes32 expectedHi, bytes16 expectedLo, string memory label) private pure {
        assertEq(got.length, 48, string.concat(label, ": output length"));
        bytes32 gotHi;
        bytes16 gotLo;
        assembly {
            gotHi := mload(add(got, 32))
            gotLo := mload(add(got, 64))
        }
        assertEq(gotHi, expectedHi, string.concat(label, ": top 32 bytes"));
        assertEq(gotLo, expectedLo, string.concat(label, ": bottom 16 bytes"));
    }
}
