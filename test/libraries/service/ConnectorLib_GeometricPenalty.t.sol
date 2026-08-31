// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConnectorLib} from "@hiero-ledger/clpr/libraries/service/ConnectorLib.sol";

contract ConnectorLibHarness {
    function geometricPenalty(uint256 base, uint256 multiplier, uint32 exp) external pure returns (uint256) {
        return ConnectorLib._geometricPenalty(base, multiplier, exp);
    }
}

contract GeometricPenaltyTest is Test {
    ConnectorLibHarness internal h;

    function setUp() public {
        h = new ConnectorLibHarness();
    }

    // ── exp = 0: base * m^0 = base ────────────────────────────────────

    function test_exp0_returnsBase() public view {
        assertEq(h.geometricPenalty(1 ether, 2, 0), 1 ether);
    }

    function test_exp0_zeroBase_returnsZero() public view {
        assertEq(h.geometricPenalty(0, 2, 0), 0);
    }

    // ── multiplier = 0 / 1: treated as no scaling ─────────────────────

    function test_multiplierZero_returnsBase() public view {
        assertEq(h.geometricPenalty(1 ether, 0, 5), 1 ether);
    }

    function test_multiplierOne_returnsBase() public view {
        assertEq(h.geometricPenalty(1 ether, 1, 10), 1 ether);
    }

    // ── exact values for small exponents ─────────────────────────────

    function test_base1_mult2_exp1() public view {
        // 1 * 2^1 = 2
        assertEq(h.geometricPenalty(1, 2, 1), 2);
    }

    function test_base1_mult2_exp8() public view {
        // 1 * 2^8 = 256
        assertEq(h.geometricPenalty(1, 2, 8), 256);
    }

    function test_base1e18_mult2_exp4() public view {
        // 1e18 * 2^4 = 16e18
        assertEq(h.geometricPenalty(1e18, 2, 4), 16e18);
    }

    function test_base1e16_mult3_exp3() public view {
        // 1e16 * 3^3 = 27e16
        assertEq(h.geometricPenalty(1e16, 3, 3), 27e16);
    }

    function test_typical_slash_progression() public view {
        // basePenalty=0.01 ether, multiplier=2: 1st slash=0.01, 2nd=0.02, 3rd=0.04
        uint256 base = 0.01 ether;
        assertEq(h.geometricPenalty(base, 2, 0), 0.01 ether);
        assertEq(h.geometricPenalty(base, 2, 1), 0.02 ether);
        assertEq(h.geometricPenalty(base, 2, 2), 0.04 ether);
        assertEq(h.geometricPenalty(base, 2, 3), 0.08 ether);
    }

    // ── overflow saturation ───────────────────────────────────────────

    function test_overflow_saturatesAtMaxUint256() public view {
        // 2^256 overflows; should return type(uint256).max
        assertEq(h.geometricPenalty(1, 2, 256), type(uint256).max);
    }

    function test_overflow_base_times_power_saturates() public view {
        // base = type(uint256).max / 2 + 1; multiplier=2; exp=1 → overflow
        uint256 base = type(uint256).max / 2 + 1;
        assertEq(h.geometricPenalty(base, 2, 1), type(uint256).max);
    }

    function test_overflow_squaringStep_saturates() public view {
        // Squaring saturates when m > uint256.max/m, i.e. m > 2^128.
        // With m = 2^128: m*m = 2^256 overflows, so the squaring guard returns max.
        uint256 bigM = 1 << 128;
        assertEq(h.geometricPenalty(1, bigM, 2), type(uint256).max);
    }

    function test_largeExp_saturates() public view {
        // Any multiplier > 1 with exp = type(uint32).max saturates
        assertEq(h.geometricPenalty(1, 2, type(uint32).max), type(uint256).max);
    }

    // ── binary exponentiation correctness ────────────────────────────
    // Verify that non-power-of-two exponents (mixed bits) are correct.

    function test_exp5_binary101() public view {
        // 2 * 3^5 = 2 * 243 = 486
        assertEq(h.geometricPenalty(2, 3, 5), 486);
    }

    function test_exp6_binary110() public view {
        // 1 * 2^6 = 64
        assertEq(h.geometricPenalty(1, 2, 6), 64);
    }

    function test_exp7_binary111() public view {
        // 1 * 2^7 = 128
        assertEq(h.geometricPenalty(1, 2, 7), 128);
    }

    // ── fuzz ──────────────────────────────────────────────────────────

    function test_fuzz_exp0_alwaysReturnsBase(uint256 base, uint256 mult) public view {
        assertEq(h.geometricPenalty(base, mult, 0), base);
    }

    function test_fuzz_multiplierLE1_alwaysReturnsBase(uint256 base, uint8 mult, uint32 exp) public view {
        vm.assume(mult <= 1);
        assertEq(h.geometricPenalty(base, mult, exp), base);
    }

    function test_fuzz_resultNeverBelowBase(uint256 base, uint256 mult, uint32 exp) public view {
        vm.assume(mult >= 1);
        uint256 result = h.geometricPenalty(base, mult, exp);
        assertGe(result, base);
    }

    function test_fuzz_resultNeverExceedsMaxUint256(uint256 base, uint256 mult, uint32 exp) public view {
        // trivially true for uint256, but validates no panic on any input
        uint256 result = h.geometricPenalty(base, mult, exp);
        assertLe(result, type(uint256).max);
    }
}
