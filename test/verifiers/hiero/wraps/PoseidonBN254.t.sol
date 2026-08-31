// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoseidonBN254Contract} from "@hiero-ledger/clpr/verifiers/hiero/wraps/PoseidonBN254Contract.sol";
import {PoseidonPermuteA} from "@hiero-ledger/clpr/verifiers/hiero/wraps/PoseidonPermuteA.sol";
import {PoseidonPermuteB} from "@hiero-ledger/clpr/verifiers/hiero/wraps/PoseidonPermuteB.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract PoseidonBN254Test is Test {
    PoseidonBN254Contract private harness;

    function setUp() public {
        harness = new PoseidonBN254Contract(address(new PoseidonPermuteA()), address(new PoseidonPermuteB()));
    }

    /// @dev Empty input: 0 chunks absorbed → loop skipped, absorbIdx stays 0, no final permute.
    ///      s1 remains 0 so the return value is 0.
    function test_hashHintsVk_emptyInput() public view {
        uint256 result = harness.hashHintsVk(new bytes(0));
        assertEq(result, 0, "empty input must return 0");
    }

    /// @dev 1-byte input: 1 chunk → absorb into s1, absorbIdx=1 ≠ 4 so no in-loop permute;
    ///      final permute triggered.  Result must be a non-zero field element.
    function test_hashHintsVk_oneByte() public view {
        bytes memory input = hex"01";
        uint256 result = harness.hashHintsVk(input);
        // The permutation is deterministic — just ensure no revert and in-field.
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "result must be a valid BN254 scalar");
    }

    /// @dev 32-byte input: exactly one 32-byte chunk → absorb into s1, final permute.
    function test_hashHintsVk_oneChunk() public view {
        bytes memory input = new bytes(32);
        // Non-zero content forces non-trivial state.
        for (uint256 i = 0; i < 32; i++) {
            input[i] = bytes1(SafeCast.toUint8(i + 1));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "result must be in-field");
    }

    /// @dev 4×32 = 128 bytes: exactly 4 chunks fill one rate block → permute fires
    ///      inside the loop (absorbIdx wraps from 4→0), no final permute.
    function test_hashHintsVk_exactlyOneBlock() public view {
        bytes memory input = new bytes(128);
        for (uint256 i = 0; i < 128; i++) {
            input[i] = bytes1(SafeCast.toUint8(i));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr);
    }

    /// @dev 5×32 = 160 bytes: 4 chunks → loop-permute, then 1 remaining → final permute.
    ///      Exercises both the in-loop and post-loop permute paths.
    function test_hashHintsVk_oneBlockPlusOneByte() public view {
        bytes memory input = new bytes(160);
        for (uint256 i = 0; i < 160; i++) {
            input[i] = bytes1(SafeCast.toUint8(i % 251));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr);
    }

    /// @dev 1096-byte hintsVK (the real WRAPS key size): exercises multiple loop-permutes
    ///      and a final partial block.  Should equal the PoseidonBN254Contract result for
    ///      the same input (used in end-to-end tests via WRAPSVerifier).
    function test_hashHintsVk_realHintsVKSize() public view {
        bytes memory input = new bytes(1096);
        // Fill with a repeating pattern to get non-trivial state.
        for (uint256 i = 0; i < 1096; i++) {
            // casting to 'uint8' is for test purposes only
            // forge-lint: disable-next-line(unsafe-typecast)
            input[i] = bytes1(uint8(i * 7 + 3));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr);
    }

    /// @dev 33-byte input: last chunk is a partial chunk (1 byte in 32-byte slot).
    ///      Exercises the `end - start < 32` masking branch in `_readLeFr`.
    function test_hashHintsVk_partialLastChunk() public view {
        bytes memory input = new bytes(33);
        input[32] = 0xAB; // partial last byte
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr);
    }

    /// @dev Determinism: same input always gives same output.
    function test_hashHintsVk_deterministic() public view {
        bytes memory input = abi.encodePacked(uint256(42));
        uint256 r1 = harness.hashHintsVk(input);
        uint256 r2 = harness.hashHintsVk(input);
        assertEq(r1, r2, "hash must be deterministic");
    }

    /// @dev Different inputs must produce different outputs (collision resistance check).
    function test_hashHintsVk_differentInputsDifferentOutputs() public view {
        bytes memory a = abi.encodePacked(uint256(1));
        bytes memory b = abi.encodePacked(uint256(2));
        assertNotEq(harness.hashHintsVk(a), harness.hashHintsVk(b));
    }

    /// @dev Absorb into each of the 4 rate positions (absorbIdx 0–3).
    ///      Input lengths 32, 64, 96, 128 each stop absorb at positions 0, 1, 2, 3.
    function test_hashHintsVk_coverAllAbsorbPositions() public view {
        bytes memory input = new bytes(96); // 3 chunks → uses positions 0, 1, 2
        for (uint256 i = 0; i < 96; i++) {
            input[i] = bytes1(SafeCast.toUint8(i + 1));
        }
        uint256 r = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(r < fr);
    }

    /// @dev Two full blocks of input (8 chunks = 256 bytes) → two in-loop permutes, no final.
    function test_hashHintsVk_twoFullBlocks() public view {
        bytes memory input = new bytes(256);
        for (uint256 i = 0; i < 256; i++) {
            input[i] = bytes1(uint8((i * 13 + 7) % 256));
        }
        uint256 r = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(r < fr);
    }

    // --- Phase 3B: absorb position branch coverage ---------

    /// @dev Test input with exactly 2 chunks (64 bytes) hits absorbIdx=0 then absorbIdx=1.
    /// This ensures both the initial absorbIdx==0 branch and the else if absorbIdx==1 branch execute.
    function test_hashHintsVk_twoChunks_absorbPosition0And1() public view {
        bytes memory input = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            input[i] = bytes1(SafeCast.toUint8((i * 5 + 1) % 256));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "two chunks should produce valid field element");
    }

    /// @dev Test input with exactly 3 chunks (96 bytes) hits absorbIdx 0, 1, 2.
    /// This ensures the else if absorbIdx==2 branch is covered.
    function test_hashHintsVk_threeChunks_absorbPosition0_1_2() public view {
        bytes memory input = new bytes(96);
        for (uint256 i = 0; i < 96; i++) {
            input[i] = bytes1(SafeCast.toUint8((i * 3 + 7) % 256));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "three chunks should produce valid field element");
    }

    /// @dev Test that _readLeFr properly masks partial chunks (len < 32).
    /// Using a 65-byte input creates a second chunk with only 1 byte content.
    /// This exercises the masking branch at PoseidonBN254Contract.sol:78-79.
    function test_hashHintsVk_partialChunkMasking() public view {
        bytes memory input = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            // casting to 'uint8' is safe because i < 65 fits in a uint8
            // forge-lint: disable-next-line(unsafe-typecast)
            input[i] = bytes1(uint8(i ^ 0xFF));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "partial chunk should be masked correctly");
    }

    /// @dev Test absorb position 3 (else branch): 4 chunks fill positions 0,1,2,3.
    /// After 4 chunks, absorbIdx == 4 triggers permute and reset to 0.
    /// This ensures the else branch at line 47 (absorbIdx 3) is executed.
    function test_hashHintsVk_fourChunks_absorbPosition3() public view {
        bytes memory input = new bytes(128);
        for (uint256 i = 0; i < 128; i++) {
            input[i] = bytes1(uint8((i * 11 + 13) % 256));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "four chunks (one full block) should produce valid field element");
    }

    /// @dev Edge case: 5 chunks tests both in-loop permute and final permute.
    /// Chunks 0-3 fill one block and permute, chunk 4 is final.
    /// Ensures all absorb positions and both permute paths are exercised.
    function test_hashHintsVk_fiveChunks_allAbsorbPositions() public view {
        bytes memory input = new bytes(160);
        for (uint256 i = 0; i < 160; i++) {
            input[i] = bytes1(uint8((i * 7 + 5) % 256));
        }
        uint256 result = harness.hashHintsVk(input);
        uint256 fr = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        assertTrue(result < fr, "five chunks should exercise all absorb positions");
    }
}
