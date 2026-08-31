// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Sha512} from "@hiero-ledger/clpr/verifiers/evm/sei/lib/Sha512.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Wraps Sha512 internal functions so they can be called from tests.
contract Sha512Harness {
    function preprocess(bytes memory message) external pure returns (bytes memory) {
        return Sha512.preprocess(message);
    }

    function hash(bytes memory data) external pure returns (uint64[8] memory) {
        return Sha512.hash(data);
    }

    function bytesToBytes8(bytes memory b, uint256 offset) external pure returns (bytes8) {
        return Sha512.bytesToBytes8(b, offset);
    }

    function ROTR(uint64 x, uint64 n) external pure returns (uint64) {
        return Sha512.ROTR(x, n);
    }

    function SHR(uint64 x, uint64 n) external pure returns (uint64) {
        return Sha512.SHR(x, n);
    }

    function Ch(uint64 x, uint64 y, uint64 z) external pure returns (uint64) {
        return Sha512.Ch(x, y, z);
    }

    function Maj(uint64 x, uint64 y, uint64 z) external pure returns (uint64) {
        return Sha512.Maj(x, y, z);
    }

    function sigma0(uint64 x) external pure returns (uint64) {
        return Sha512.sigma0(x);
    }

    function sigma1(uint64 x) external pure returns (uint64) {
        return Sha512.sigma1(x);
    }

    function gamma0(uint64 x) external pure returns (uint64) {
        return Sha512.gamma0(x);
    }

    function gamma1(uint64 x) external pure returns (uint64) {
        return Sha512.gamma1(x);
    }
}

contract Sha512Test is Test {
    Sha512Harness harness;

    function setUp() public {
        harness = new Sha512Harness();
    }

    // ── preprocess: normal-padding branch (length % 128 < 112) ───────────────

    function test_preprocess_1ByteMessage_normalPadding() public view {
        bytes memory input = hex"61";
        bytes memory padded = harness.preprocess(input);
        // 1 % 128 = 1 < 112 → padding = 127 → total = 128
        assertEq(padded.length, 128);
        assertEq(padded[0], bytes1(0x61));
        assertEq(padded[1], bytes1(0x80));
        // bit length = 8, stored in last 16 bytes big-endian: last byte = 0x08
        assertEq(padded[127], bytes1(0x08));
    }

    function test_preprocess_exactBoundary128_addsFullBlock() public view {
        bytes memory input = new bytes(128);
        bytes memory padded = harness.preprocess(input);
        // 128 % 128 = 0 < 112 → padding = 128 → total = 256
        assertEq(padded.length, 256);
        assertEq(padded[128], bytes1(0x80));
    }

    // ── preprocess: extended-padding branch (length % 128 >= 112) ────────────

    function test_preprocess_112ByteMessage_extraBlockPadding() public view {
        bytes memory input = new bytes(112);
        bytes memory padded = harness.preprocess(input);
        // 112 % 128 = 112 >= 112 → padding = 256 - 112 = 144 → total = 256
        assertEq(padded.length, 256, "112-byte input needs two full 128-byte blocks");
        assertEq(padded[112], bytes1(0x80), "separator byte must follow message");
        // bit length = 112 * 8 = 896 = 0x380; stored big-endian in last 16 bytes
        assertEq(padded[253], bytes1(0x00));
        assertEq(padded[254], bytes1(0x03));
        assertEq(padded[255], bytes1(0x80));
    }

    function test_preprocess_127ByteMessage_extraBlockPadding() public view {
        bytes memory input = new bytes(127);
        bytes memory padded = harness.preprocess(input);
        // 127 % 128 = 127 >= 112 → padding = 256 - 127 = 129 → total = 256
        assertEq(padded.length, 256);
        assertEq(padded[127], bytes1(0x80));
    }

    // ── SHA-512 known test vectors ────────────────────────────────────────────

    // NIST FIPS 180-4 test vector: SHA-512("abc")
    function test_hash_abc_nistVector() public view {
        uint64[8] memory result = harness.hash(bytes("abc"));
        assertEq(result[0], uint64(0xddaf35a193617aba));
        assertEq(result[1], uint64(0xcc417349ae204131));
        assertEq(result[2], uint64(0x12e6fa4e89a97ea2));
        assertEq(result[3], uint64(0x0a9eeee64b55d39a));
        assertEq(result[4], uint64(0x2192992a274fc1a8));
        assertEq(result[5], uint64(0x36ba3c23a3feebbd));
        assertEq(result[6], uint64(0x454d4423643ce80e));
        assertEq(result[7], uint64(0x2a9ac94fa54ca49f));
    }

    // SHA-512("") — NIST vector for empty message
    function test_hash_empty_nistVector() public view {
        uint64[8] memory result = harness.hash(bytes(""));
        assertEq(result[0], uint64(0xcf83e1357eefb8bd));
        assertEq(result[1], uint64(0xf1542850d66d8007));
        assertEq(result[2], uint64(0xd620e4050b5715dc));
        assertEq(result[3], uint64(0x83f4a921d36ce9ce));
        assertEq(result[4], uint64(0x47d0d13c5d85f2b0));
        assertEq(result[5], uint64(0xff8318d2877eec2f));
        assertEq(result[6], uint64(0x63b931bd47417a81));
        assertEq(result[7], uint64(0xa538327af927da3e));
    }

    // Hash of a 112-byte message exercises the extended-padding path end-to-end.
    function test_hash_112ByteMessage_nonZeroResult() public view {
        bytes memory input = new bytes(112);
        for (uint256 i = 0; i < 112; i++) {
            input[i] = bytes1(SafeCast.toUint8(i + 1));
        }
        uint64[8] memory result = harness.hash(input);
        bool nonZero;
        for (uint256 i = 0; i < 8; i++) {
            if (result[i] != 0) {
                nonZero = true;
                break;
            }
        }
        assertTrue(nonZero, "SHA-512 hash must be non-zero");
    }

    // Identical inputs must produce identical outputs.
    function test_hash_deterministic() public view {
        bytes memory input = bytes("hello world");
        uint64[8] memory r1 = harness.hash(input);
        uint64[8] memory r2 = harness.hash(input);
        for (uint256 i = 0; i < 8; i++) {
            assertEq(r1[i], r2[i]);
        }
    }

    // ── bytesToBytes8 ─────────────────────────────────────────────────────────

    function test_bytesToBytes8_bigEndianRead() public view {
        bytes memory data = hex"0102030405060708";
        bytes8 out = harness.bytesToBytes8(data, 0);
        assertEq(uint64(out), 0x0102030405060708);
    }

    function test_bytesToBytes8_nonZeroOffset() public view {
        bytes memory data = hex"000000000102030405060708";
        bytes8 out = harness.bytesToBytes8(data, 4);
        assertEq(uint64(out), 0x0102030405060708);
    }

    // ── Rotate / shift primitives ─────────────────────────────────────────────

    function test_ROTR_by1_rotatesLSBtoMSB() public view {
        assertEq(harness.ROTR(uint64(1), 1), uint64(0x8000000000000000));
    }

    function test_ROTR_by0_isIdentity() public view {
        uint64 x = 0xdeadbeefcafebabe;
        assertEq(harness.ROTR(x, 0), x);
    }

    function test_SHR_fillsWithZeros() public view {
        assertEq(harness.SHR(uint64(0x8000000000000000), 1), uint64(0x4000000000000000));
        assertEq(harness.SHR(uint64(1), 1), uint64(0));
    }

    // ── Boolean mixing functions ──────────────────────────────────────────────

    function test_Ch_allOnesSelect_y() public view {
        uint64 y = 0x1234567890abcdef;
        assertEq(harness.Ch(uint64(0xffffffffffffffff), y, 0), y);
    }

    function test_Ch_allZerosSelect_z() public view {
        uint64 z = 0xfedcba9876543210;
        assertEq(harness.Ch(uint64(0), 0, z), z);
    }

    function test_Maj_twoTrueWins() public view {
        // Maj(1,1,0) = 1; Maj(1,0,0) = 0
        assertEq(harness.Maj(uint64(0xff), uint64(0xff), uint64(0)), uint64(0xff));
        assertEq(harness.Maj(uint64(0xff), uint64(0), uint64(0)), uint64(0));
    }

    // ── Sigma / gamma schedule functions ─────────────────────────────────────

    function test_sigma0_nonZeroInput() public view {
        uint64 v = 0x1234567890abcdef;
        assertGt(harness.sigma0(v), 0);
    }

    function test_sigma1_nonZeroInput() public view {
        uint64 v = 0x1234567890abcdef;
        assertGt(harness.sigma1(v), 0);
    }

    function test_gamma0_nonZeroInput() public view {
        uint64 v = 0xabcdef1234567890;
        assertGt(harness.gamma0(v), 0);
    }

    function test_gamma1_nonZeroInput() public view {
        uint64 v = 0xabcdef1234567890;
        assertGt(harness.gamma1(v), 0);
    }

    // All schedule functions must be deterministic.
    function test_scheduleHelpers_deterministic() public view {
        uint64 v = 0xdeadbeefcafebabe;
        assertEq(harness.sigma0(v), harness.sigma0(v));
        assertEq(harness.sigma1(v), harness.sigma1(v));
        assertEq(harness.gamma0(v), harness.gamma0(v));
        assertEq(harness.gamma1(v), harness.gamma1(v));
    }

    // Distinct inputs must produce distinct outputs (collision sanity check).
    function test_scheduleHelpers_distinctInputs_distinctOutputs() public view {
        uint64 a = 1;
        uint64 b = 2;
        assertTrue(harness.sigma0(a) != harness.sigma0(b) || harness.sigma1(a) != harness.sigma1(b));
    }
}
