// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BN254Util
/// @notice BN254 G1/G2 arithmetic helpers for WRAPS Groth16 verification.
///         All external point formats are EIP-196/197 big-endian.
///         Input compressed points are Arkworks 32-byte (G1) / 64-byte (G2) LE format.
library BN254Util {
    /// @notice Fp2 square root failed — the compressed G2 point encodes no valid curve point.
    error BN254G2SqrtFailed();

    // BN254 Fq (base field prime)
    uint256 internal constant FQ = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    // (FQ + 1) / 4  — for sqrt when FQ ≡ 3 mod 4
    uint256 internal constant FQ_SQRT_EXP =
        5472060717959818805561601436314318772174077789324455915672259473661306552146;
    // (FQ - 1) / 2  — for Euler criterion (QR check)
    uint256 internal constant FQ_HALF = 10944121435919637611123202872628637544348155578648911831344518947322613104291;
    // modular inverse of 2 mod FQ = (FQ + 1) / 2
    uint256 internal constant FQ_INV2 = 10944121435919637611123202872628637544348155578648911831344518947322613104292;
    // FQ - 2 (for modular inverse via Fermat)
    uint256 internal constant FQ_MINUS2 = 21888242871839275222246405745257275088696311157297823662689037894645226208581;
    // BN254 G2 twist constant B = (B_C0, B_C1) in Fp2
    uint256 internal constant G2_B_C0 = 19485874751759354771024239261021720505790618469301721065564631296452457478373;
    uint256 internal constant G2_B_C1 = 266929791119991161246907387137283842545076965332900288569378510910307636690;
    // 55-bit mask for nonnative limb decomposition
    uint256 internal constant LIMB_MASK = 0x7FFFFFFFFFFFFF; // (1 << 55) - 1

    /// @notice Decompress a 32-byte Arkworks G1 point (LE) into EIP-196 (x, y) pair.
    ///         Returns (0, 0) for the point at infinity.
    function decompressG1(bytes32 compressed) internal view returns (uint256 x, uint256 y) {
        uint256 raw = uint256(compressed);
        // Flags in the LS byte (byte[31] in LE = LSB in uint256-as-BE-of-LE)
        uint8 flags = SafeCast.toUint8(raw & 0xFF);
        bool isInfinity = (flags & 0x40) != 0;
        if (isInfinity) return (0, 0);
        bool yNeg = (flags & 0x80) != 0;

        // Clear flag bits from LS byte, then bswap to get BE x-coordinate
        raw = (raw & ~uint256(0xC0)) | (raw & ~uint256(0xFF)); // clear bits 7,6 of LS byte
        // Simpler: mask the bottom byte to 0x3F, keep everything else
        raw = (raw >> 8) << 8 | (raw & 0x3F);
        x = _bswap32(raw);

        // Recover y: y^2 = x^3 + 3 mod FQ
        uint256 y2 = addmod(mulmod(mulmod(x, x, FQ), x, FQ), 3, FQ);
        y = _modexp(y2, FQ_SQRT_EXP, FQ);

        // Apply sign correction: yNeg = true means y should be the larger root (y > FQ/2)
        bool yIsLarge = y > FQ_HALF;
        if (yNeg != yIsLarge) {
            y = FQ - y;
        }
    }

    /// @notice Decompress a 64-byte Arkworks G2 point (x.c0 LE || x.c1 LE with flags in c1's byte[31])
    ///         into EIP-197 format: (xc1, xc0, yc1, yc0) all BE.
    function decompressG2(bytes32 c0raw, bytes32 c1raw)
        internal
        view
        returns (uint256 xc1, uint256 xc0, uint256 yc1, uint256 yc0)
    {
        uint256 raw1 = uint256(c1raw);
        uint8 flags = SafeCast.toUint8(raw1 & 0xFF);
        bool isInfinity = (flags & 0x40) != 0;
        if (isInfinity) return (0, 0, 0, 0);
        bool yNeg = (flags & 0x80) != 0;

        // Clear flags from c1's LS byte
        raw1 = (raw1 >> 8) << 8 | (raw1 & 0x3F);
        xc1 = _bswap32(raw1);
        xc0 = _bswap32(uint256(c0raw));

        // Compute x^3 + B in Fp2
        // x^3 = (xc0 + xc1*u)^3 where u^2 = -1
        // real: xc0^3 - 3*xc0*xc1^2 + B_C0
        // imag: 3*xc0^2*xc1 - xc1^3 + B_C1
        (uint256 rhsRe, uint256 rhsIm) = _fp2CubePlusB(xc0, xc1);

        // Compute sqrt of rhs in Fp2
        bool ok;
        (ok, yc0, yc1) = _fp2Sqrt(rhsRe, rhsIm);
        if (!ok) revert BN254G2SqrtFailed();

        // Apply sign correction: yNeg = true means yc1 should be > FQ/2
        bool yc1Large = yc1 > FQ_HALF;
        if (yNeg != yc1Large) {
            // negate: -(a + b*u) = (FQ-a) + (FQ-b)*u
            if (yc0 != 0) yc0 = FQ - yc0;
            if (yc1 != 0) yc1 = FQ - yc1;
        }
    }

    /// @notice EIP-196 ecAdd: P + Q → R, all in BE (x, y) format.
    function ecAdd(uint256 px, uint256 py, uint256 qx, uint256 qy) internal view returns (uint256 rx, uint256 ry) {
        uint256[4] memory input = [px, py, qx, qy];
        uint256[2] memory output;
        assembly ("memory-safe") {
            if iszero(staticcall(gas(), 6, input, 0x80, output, 0x40)) {
                revert(0, 0)
            }
        }
        rx = output[0];
        ry = output[1];
    }

    /// @notice EIP-196 ecMul: scalar * P → R, P in BE (x, y), scalar is uint256.
    function ecMul(uint256 px, uint256 py, uint256 scalar) internal view returns (uint256 rx, uint256 ry) {
        uint256[3] memory input = [px, py, scalar];
        uint256[2] memory output;
        assembly ("memory-safe") {
            if iszero(staticcall(gas(), 7, input, 0x60, output, 0x40)) {
                revert(0, 0)
            }
        }
        rx = output[0];
        ry = output[1];
    }

    /// @notice Negate a G1 point: (x, y) → (x, FQ - y). Returns (0,0) unchanged.
    function g1Neg(uint256 x, uint256 y) internal pure returns (uint256, uint256) {
        if (x == 0 && y == 0) return (0, 0);
        return (x, FQ - y);
    }

    /// @notice EIP-197 ecPairing. input is 192-byte pairs: G1(64B) || G2(128B) per pair.
    ///         Returns true iff product of pairings equals identity.
    function ecPairing(bytes memory input) internal view returns (bool) {
        uint256 len = input.length;
        uint256[1] memory output;
        assembly ("memory-safe") {
            if iszero(staticcall(gas(), 8, add(input, 0x20), len, output, 0x20)) {
                revert(0, 0)
            }
        }
        return output[0] == 1;
    }

    /// @notice Decompose a BN254 Fq element into 5 × 55-bit limbs (LE order).
    ///         limbs[0] = bits 0..54, limbs[4] = bits 220..253.
    function fqToLimbs(uint256 x) internal pure returns (uint256[5] memory limbs) {
        limbs[0] = x & LIMB_MASK;
        limbs[1] = (x >> 55) & LIMB_MASK;
        limbs[2] = (x >> 110) & LIMB_MASK;
        limbs[3] = (x >> 165) & LIMB_MASK;
        limbs[4] = x >> 220;
    }

    function _fp2CubePlusB(uint256 a, uint256 b) private pure returns (uint256 re, uint256 im) {
        uint256 a2 = mulmod(a, a, FQ);
        uint256 b2 = mulmod(b, b, FQ);
        // re = a^3 - 3*a*b^2 + B_C0 = a*(a^2 - 3*b^2) + B_C0
        uint256 a2M3b2 = addmod(a2, FQ - mulmod(3, b2, FQ), FQ);
        re = addmod(mulmod(a, a2M3b2, FQ), G2_B_C0, FQ);
        // im = 3*a^2*b - b^3 + B_C1 = b*(3*a^2 - b^2) + B_C1
        uint256 _3a2Mb2 = addmod(mulmod(3, a2, FQ), FQ - b2, FQ);
        im = addmod(mulmod(b, _3a2Mb2, FQ), G2_B_C1, FQ);
    }

    /// @notice Compute sqrt(a + b*u) in Fp2 = Fp[u]/(u^2+1).
    ///         Algorithm: uses Fp sqrt for the norm ||a+b*u||_Fp = sqrt(a^2+b^2).
    function _fp2Sqrt(uint256 a, uint256 b) private view returns (bool success, uint256 ra, uint256 rb) {
        if (a == 0 && b == 0) return (true, 0, 0);

        // t0 = a^2 + b^2 (the Fp norm of the Fp2 element)
        uint256 t0 = addmod(mulmod(a, a, FQ), mulmod(b, b, FQ), FQ);

        // Euler criterion: t0 must be a QR in Fp
        if (_modexp(t0, FQ_HALF, FQ) != 1) return (false, 0, 0);

        // Compute norm = sqrt(t0) in Fp
        uint256 norm = _modexp(t0, FQ_SQRT_EXP, FQ);

        // Try xRe = (a + norm) / 2
        uint256 xRe = mulmod(addmod(a, norm, FQ), FQ_INV2, FQ);

        // Check if xRe is a QR
        if (_modexp(xRe, FQ_HALF, FQ) != 1) {
            // Use xRe = (a - norm) / 2
            xRe = mulmod(addmod(a, FQ - norm, FQ), FQ_INV2, FQ);
        }

        // ra = sqrt(xRe)
        ra = _modexp(xRe, FQ_SQRT_EXP, FQ);
        if (ra == 0) {
            // ra = 0 means xRe = 0, handle b separately
            rb = _modexp(mulmod(b, FQ_INV2, FQ), FQ_SQRT_EXP, FQ);
        } else {
            // rb = b / (2 * ra) = b * inv(2*ra)
            rb = mulmod(b, _modexp(mulmod(2, ra, FQ), FQ_MINUS2, FQ), FQ);
        }
        return (true, ra, rb);
    }

    /// @notice Reverse all 32 bytes of a uint256 (BE ↔ LE conversion).
    function _bswap32(uint256 x) internal pure returns (uint256) {
        x = ((x & 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00) >> 8)
            | ((x & 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF) << 8);
        x = ((x & 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000) >> 16)
            | ((x & 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF) << 16);
        x = ((x & 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000) >> 32)
            | ((x & 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF) << 32);
        x = ((x & 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000) >> 64)
            | ((x & 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF) << 64);
        x = (x >> 128) | (x << 128);
        return x;
    }

    function _modexp(uint256 base, uint256 exponent, uint256 modulus) private view returns (uint256 result) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x20)
            mstore(add(ptr, 0x20), 0x20)
            mstore(add(ptr, 0x40), 0x20)
            mstore(add(ptr, 0x60), base)
            mstore(add(ptr, 0x80), exponent)
            mstore(add(ptr, 0xa0), modulus)
            if iszero(staticcall(gas(), 5, ptr, 0xc0, ptr, 0x20)) { revert(0, 0) }
            result := mload(ptr)
        }
    }
}
