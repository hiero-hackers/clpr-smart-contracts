// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {BN254Util} from "@hiero-ledger/clpr/verifiers/hiero/wraps/BN254Util.sol";
import {WRAPSVerificationKey as VK} from "@hiero-ledger/clpr/verifiers/hiero/wraps/WRAPSVerificationKey.sol";

interface IPoseidonBN254 {
    function hashHintsVk(bytes calldata hintsVk) external view returns (uint256);
}

/// @title WRAPSVerifier
/// @notice Verifies the 704-byte WRAPS Nova IVC + Groth16 decider proof (settled-block path).
///
/// ProofData layout (Arkworks CanonicalSerialize, LE):
///   [0..31]    i          : Fr (32 bytes LE)
///   [32..39]   z_0 count  : u64 LE = 2
///   [40..103]  z_0[0..1]  : 2 × Fr
///   [104..111] z_i count  : u64 LE = 2
///   [112..175] z_i[0..1]  : 2 × Fr
///   [176..183] U_i count  : u64 LE = 2
///   [184..247] U_i[0..1]  : 2 × compressed G1 (cmW, cmE)
///   [248..255] u_i count  : u64 LE = 2
///   [256..319] u_i[0..1]  : 2 × compressed G1 (cmW, cmE=infinity)
///   [320..351] A          : compressed G1
///   [352..415] B          : compressed G2 (c0 LE || c1 LE)
///   [416..447] C          : compressed G1
///   [448..479] kzg[0].eval: Fr
///   [480..511] kzg[0].w   : compressed G1
///   [512..543] kzg[1].eval: Fr
///   [544..575] kzg[1].w   : compressed G1
///   [576..607] cmT        : compressed G1
///   [608..639] r          : Fr
///   [640..671] kzgChal[0] : Fr
///   [672..703] kzgChal[1] : Fr
library WRAPSVerifier {
    /// @notice The proof blob is not exactly 704 bytes.
    error WRAPSInvalidProofLength();
    /// @notice The proof's z_0[0] does not match the expected ledger id.
    error WRAPSLedgerIdMismatch();
    /// @notice The proof's z_i[1] does not equal Poseidon(hintsVk).
    error WRAPSPoseidonMismatch();
    /// @notice u_i.cmE is not the infinity point (protocol invariant violation).
    error WRAPSCmENotInfinity();
    /// @notice The merged ecPairing check failed.
    error WRAPSPairingFailed();
    /// @notice A VK static-slice request falls outside the 704-byte constant.
    error WRAPSSliceOutOfBounds();

    uint256 private constant OFF_I = 0;
    uint256 private constant OFF_Z0 = 40; // z_0[0]; +32 for z_0[1]
    uint256 private constant OFF_ZI = 112; // z_i[0]; +32 for z_i[1]
    uint256 private constant OFF_U_CMW = 184; // U_i.cmW
    uint256 private constant OFF_U_CME = 216; // U_i.cmE
    uint256 private constant OFF_SMALL_U_CMW = 256; // u_i.cmW
    uint256 private constant OFF_SMALL_U_CME = 288; // u_i.cmE (must be infinity)
    uint256 private constant OFF_PROOF_A = 320; // Groth16 A
    uint256 private constant OFF_PROOF_B_C0 = 352; // Groth16 B c0
    uint256 private constant OFF_PROOF_B_C1 = 384; // Groth16 B c1
    uint256 private constant OFF_PROOF_C = 416; // Groth16 C
    uint256 private constant OFF_KZG0_EVAL = 448;
    uint256 private constant OFF_KZG0_W = 480;
    uint256 private constant OFF_KZG1_EVAL = 512;
    uint256 private constant OFF_KZG1_W = 544;
    uint256 private constant OFF_CMT = 576;
    uint256 private constant OFF_R = 608;
    uint256 private constant OFF_KZG_CHAL0 = 640;
    uint256 private constant OFF_KZG_CHAL1 = 672;

    uint256 private constant PROOF_LEN = 704;

    /// @notice Verify a 704-byte WRAPS abProof.
    /// @param abProof   704-byte Arkworks-serialized ProofData
    /// @param hintsVk   1096-byte hinTS VK (used to compute Poseidon public input)
    /// @param ledgerId  32-byte trust-anchor ledger id (raw LE Fr bytes)
    /// @param poseidon  Deployed PoseidonBN254Contract address (called externally to avoid inlining)
    function verify(bytes calldata abProof, bytes calldata hintsVk, bytes calldata ledgerId, address poseidon)
        internal
        view
        returns (bool)
    {
        if (abProof.length != PROOF_LEN) revert WRAPSInvalidProofLength();

        // ── 1. Check ledgerId anchor (raw LE bytes comparison)
        if (!_eq32(abProof, OFF_Z0, ledgerId, 0)) revert WRAPSLedgerIdMismatch();

        uint256 zi1 = _leToFr(abProof, OFF_ZI + 32);
        // ── 2. Check Poseidon(hintsVk) == z_i[1] ─────────────────────────────
        if (poseidon != address(0)) {
            uint256 poseidonHash = IPoseidonBN254(poseidon).hashHintsVk(hintsVk);
            if (zi1 != poseidonHash) revert WRAPSPoseidonMismatch();
        }

        // ── 3. Decompress G1 commitment points
        (uint256 ucmWx, uint256 ucmWy) = BN254Util.decompressG1(_cd32(abProof, OFF_U_CMW));
        (uint256 ucmEx, uint256 ucmEy) = BN254Util.decompressG1(_cd32(abProof, OFF_U_CME));
        (uint256 smallUcmWx, uint256 smallUcmWy) = BN254Util.decompressG1(_cd32(abProof, OFF_SMALL_U_CMW));
        // u_i.cmE must be the infinity point (protocol invariant)
        if ((_cdWord(abProof, OFF_SMALL_U_CME) & 0x40) == 0) revert WRAPSCmENotInfinity();

        (uint256 cmTx, uint256 cmTy) = BN254Util.decompressG1(_cd32(abProof, OFF_CMT));
        (uint256 proofAx, uint256 proofAy) = BN254Util.decompressG1(_cd32(abProof, OFF_PROOF_A));
        (uint256 proofCx, uint256 proofCy) = BN254Util.decompressG1(_cd32(abProof, OFF_PROOF_C));
        (uint256 kzg0Wx, uint256 kzg0Wy) = BN254Util.decompressG1(_cd32(abProof, OFF_KZG0_W));
        (uint256 kzg1Wx, uint256 kzg1Wy) = BN254Util.decompressG1(_cd32(abProof, OFF_KZG1_W));

        // ── 4. Decompress G2 proof point B
        (uint256 proofBXc1, uint256 proofBXc0, uint256 proofBYc1, uint256 proofBYc0) =
            BN254Util.decompressG2(_cd32(abProof, OFF_PROOF_B_C0), _cd32(abProof, OFF_PROOF_B_C1));

        // ── 5. Fold commitments: cmW = U.cmW + r*u.cmW; cmE = U.cmE + r*cmT
        uint256 r = _leToFr(abProof, OFF_R);
        (uint256 cmWx, uint256 cmWy) = _foldG1(ucmWx, ucmWy, smallUcmWx, smallUcmWy, r);
        (uint256 cmEx, uint256 cmEy) = _foldG1(ucmEx, ucmEy, cmTx, cmTy, r);

        // ── 6. Read remaining scalars
        uint256 kzgChal0 = _leToFr(abProof, OFF_KZG_CHAL0);
        uint256 kzgChal1 = _leToFr(abProof, OFF_KZG_CHAL1);
        uint256 kzgEval0 = _leToFr(abProof, OFF_KZG0_EVAL);
        uint256 kzgEval1 = _leToFr(abProof, OFF_KZG1_EVAL);

        // ── 7. Build 40 public inputs
        uint256[40] memory pi;
        pi[0] = VK.PP_HASH;
        pi[1] = _leToFr(abProof, OFF_I);
        pi[2] = _leToFr(abProof, OFF_Z0);
        pi[3] = _leToFr(abProof, OFF_Z0 + 32);
        pi[4] = _leToFr(abProof, OFF_ZI);
        pi[5] = zi1;
        _limbs10(cmWx, cmWy, pi, 6);
        _limbs10(cmEx, cmEy, pi, 16);
        pi[26] = kzgChal0;
        pi[27] = kzgChal1;
        pi[28] = kzgEval0;
        pi[29] = kzgEval1;
        _limbs10(cmTx, cmTy, pi, 30);

        // ── 8. Compute vk_x = gamma_abc[0] + Σ pi[k] * gamma_abc[k+1]
        // Single 160-byte buffer reused every iteration: eliminates 40×160-byte
        // allocations and the quadratic memory expansion cost they incur.
        // Buffer layout: [0x00] acc.x [0x20] acc.y [0x40] base.x [0x60] base.y [0x80] scalar
        uint256 vkxX;
        uint256 vkxY;
        (vkxX, vkxY) = VK.gammaAbc(0);
        {
            uint256 buf;
            assembly ("memory-safe") {
                buf := mload(0x40)
                mstore(0x40, add(buf, 0xa0))
            }
            for (uint256 k = 0; k < 40;) {
                (uint256 gx, uint256 gy) = VK.gammaAbc(k + 1);
                uint256 sc = pi[k];
                assembly ("memory-safe") {
                    // ecMul: [base.x, base.y, scalar] → mul result at buf+0x40
                    mstore(add(buf, 0x40), gx)
                    mstore(add(buf, 0x60), gy)
                    mstore(add(buf, 0x80), sc)
                    if iszero(staticcall(gas(), 0x07, add(buf, 0x40), 0x60, add(buf, 0x40), 0x40)) {
                        revert(0, 0)
                    }
                    // ecAdd: [acc.x, acc.y, mul.x, mul.y] → new acc at buf+0x00
                    mstore(buf, vkxX)
                    mstore(add(buf, 0x20), vkxY)
                    if iszero(staticcall(gas(), 0x06, buf, 0x80, buf, 0x40)) {
                        revert(0, 0)
                    }
                    vkxX := mload(buf)
                    vkxY := mload(add(buf, 0x20))
                }
                unchecked {
                    ++k;
                }
            }
        }

        //          One call costs 34000×8+45000 = 317000 gas vs three separate calls at
        //          (181000 + 113000 + 113000) = 407000 gas. Saves 90000 gas.
        {
            (uint256 negAx, uint256 negAy) = BN254Util.g1Neg(proofAx, proofAy);

            // Pre-compute KZG G1 inputs (same logic as old _verifyKZG but inlined)
            // KZG0: lhs = cmW - eval0*g + chal0*w0
            (uint256 eg0x, uint256 eg0y) = BN254Util.ecMul(VK.KZG_G_X, VK.KZG_G_Y, kzgEval0);
            (uint256 negEg0x, uint256 negEg0y) = BN254Util.g1Neg(eg0x, eg0y);
            (uint256 lhs0x, uint256 lhs0y) = BN254Util.ecAdd(cmWx, cmWy, negEg0x, negEg0y);
            (uint256 cw0x, uint256 cw0y) = BN254Util.ecMul(kzg0Wx, kzg0Wy, kzgChal0);
            (uint256 kzg0Lhsx, uint256 kzg0Lhsy) = BN254Util.ecAdd(lhs0x, lhs0y, cw0x, cw0y);
            (uint256 negW0x, uint256 negW0y) = BN254Util.g1Neg(kzg0Wx, kzg0Wy);

            // KZG1: lhs = cmE - eval1*g + chal1*w1
            (uint256 eg1x, uint256 eg1y) = BN254Util.ecMul(VK.KZG_G_X, VK.KZG_G_Y, kzgEval1);
            (uint256 negEg1x, uint256 negEg1y) = BN254Util.g1Neg(eg1x, eg1y);
            (uint256 lhs1x, uint256 lhs1y) = BN254Util.ecAdd(cmEx, cmEy, negEg1x, negEg1y);
            (uint256 cw1x, uint256 cw1y) = BN254Util.ecMul(kzg1Wx, kzg1Wy, kzgChal1);
            (uint256 kzg1Lhsx, uint256 kzg1Lhsy) = BN254Util.ecAdd(lhs1x, lhs1y, cw1x, cw1y);
            (uint256 negW1x, uint256 negW1y) = BN254Util.g1Neg(kzg1Wx, kzg1Wy);

            // Build pairing input using pre-packed static VK bytes to reduce stack usage under --ir-minimum.
            bytes memory inp = bytes.concat(
                // Pair 1: -A and B (entirely dynamic)
                abi.encodePacked(negAx, negAy, proofBXc1, proofBXc0, proofBYc1, proofBYc0),
                // Pair 2: alpha_g1 ++ beta_g2 (static 192 B)
                _vkStaticSlice(0, 192),
                // Pair 3: vkx (dynamic) ++ gamma_g2 (static 128 B)
                abi.encodePacked(vkxX, vkxY),
                _vkStaticSlice(192, 128),
                // Pair 4: proofC (dynamic) ++ delta_g2 (static 128 B)
                abi.encodePacked(proofCx, proofCy),
                _vkStaticSlice(320, 128),
                // Pair 5: kzg0_lhs (dynamic) ++ kzg_h (static 128 B)
                abi.encodePacked(kzg0Lhsx, kzg0Lhsy),
                _vkStaticSlice(448, 128),
                // Pair 6: -w0 (dynamic) ++ kzg_beta_h (static 128 B)
                abi.encodePacked(negW0x, negW0y),
                _vkStaticSlice(576, 128),
                // Pair 7: kzg1_lhs (dynamic) ++ kzg_h (static 128 B)
                abi.encodePacked(kzg1Lhsx, kzg1Lhsy),
                _vkStaticSlice(448, 128),
                // Pair 8: -w1 (dynamic) ++ kzg_beta_h (static 128 B)
                abi.encodePacked(negW1x, negW1y),
                _vkStaticSlice(576, 128)
            );
            if (!BN254Util.ecPairing(inp)) revert WRAPSPairingFailed();
        }

        return true;
    }

    /// @dev P + r*Q using ecMul + ecAdd.
    function _foldG1(uint256 px, uint256 py, uint256 qx, uint256 qy, uint256 r)
        private
        view
        returns (uint256 rx, uint256 ry)
    {
        (uint256 sx, uint256 sy) = BN254Util.ecMul(qx, qy, r);
        (rx, ry) = BN254Util.ecAdd(px, py, sx, sy);
    }

    /// @dev Write 10 nonnative limbs (x: 5, y: 5) of a G1 point into pi[base..base+9].
    function _limbs10(uint256 gx, uint256 gy, uint256[40] memory pi, uint256 base) private pure {
        uint256[5] memory lx = BN254Util.fqToLimbs(gx);
        uint256[5] memory ly = BN254Util.fqToLimbs(gy);
        for (uint256 j = 0; j < 5; j++) {
            pi[base + j] = lx[j];
            pi[base + 5 + j] = ly[j];
        }
    }

    /// @dev Returns a slice [offset .. offset+len) from VK.VK_PAIRING_STATIC.
    ///      Using a bytes constant and slicing avoids materializing many VK constants
    ///      into the verify() stack frame under --ir-minimum / coverage.
    function _vkStaticSlice(uint256 offset, uint256 len) private pure returns (bytes memory out) {
        // 704 is the total size of VK_PAIRING_STATIC as documented in WRAPSVerificationKey.sol
        if (offset + len > 704) revert WRAPSSliceOutOfBounds();
        bytes memory data = VK.VK_PAIRING_STATIC;
        out = new bytes(len);
        assembly ("memory-safe") {
            let src := add(add(data, 0x20), offset)
            let dst := add(out, 0x20)
            // copy in 32-byte chunks
            let n := div(len, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(dst, mload(src))
                dst := add(dst, 0x20)
                src := add(src, 0x20)
            }
            // copy tail (len % 32 bytes)
            let r := mod(len, 0x20)
            if gt(r, 0) {
                // It's safe to store a full word; bytes length limits visibility.
                mstore(dst, mload(src))
            }
        }
    }

    /// @dev Read 32 bytes from calldata at data[offset] as bytes32.
    function _cd32(bytes calldata data, uint256 offset) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := calldataload(add(data.offset, offset))
        }
    }

    /// @dev Read 32 bytes from calldata at data[offset] as uint256 (BE of the raw bytes).
    ///      Used to extract flag bits from a compressed G1 LS byte.
    function _cdWord(bytes calldata data, uint256 offset) private pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := calldataload(add(data.offset, offset))
        }
    }

    /// @dev Read 32 LE bytes from calldata at data[offset] and return the field element value.
    function _leToFr(bytes calldata data, uint256 offset) private pure returns (uint256) {
        bytes32 raw;
        assembly ("memory-safe") {
            raw := calldataload(add(data.offset, offset))
        }
        return BN254Util._bswap32(uint256(raw));
    }

    /// @dev Compare 32 bytes at a[aOff] against b[bOff].
    function _eq32(bytes calldata a, uint256 aOff, bytes calldata b, uint256 bOff) private pure returns (bool) {
        bytes32 av;
        bytes32 bv;
        assembly ("memory-safe") {
            av := calldataload(add(a.offset, aOff))
            bv := calldataload(add(b.offset, bOff))
        }
        return av == bv;
    }
}
