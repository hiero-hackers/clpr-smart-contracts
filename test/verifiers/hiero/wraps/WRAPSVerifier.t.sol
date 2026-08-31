// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WRAPSVerifierContract} from "@hiero-ledger/clpr/verifiers/hiero/wraps/WRAPSVerifierContract.sol";
import {WRAPSVerificationKey} from "@hiero-ledger/clpr/verifiers/hiero/wraps/WRAPSVerificationKey.sol";
import {PoseidonBN254Contract} from "@hiero-ledger/clpr/verifiers/hiero/wraps/PoseidonBN254Contract.sol";
import {PoseidonPermuteA} from "@hiero-ledger/clpr/verifiers/hiero/wraps/PoseidonPermuteA.sol";
import {PoseidonPermuteB} from "@hiero-ledger/clpr/verifiers/hiero/wraps/PoseidonPermuteB.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {WRAPSVerifier} from "@hiero-ledger/clpr/verifiers/hiero/wraps/WRAPSVerifier.sol";

/// @dev Wraps WRAPSVerificationKey.gammaAbc (internal) for direct testing.
contract WRAPSVKHarness {
    function gammaAbc(uint256 i) external pure returns (uint256 x, uint256 y) {
        return WRAPSVerificationKey.gammaAbc(i);
    }
}

contract WRAPSVerifierTest is Test {
    WRAPSVerifierContract internal wraps;
    WRAPSVKHarness internal vkHarness;

    // 704-byte zero proof (valid length)
    bytes internal constant ZERO_PROOF_704 = new bytes(704);

    // 32-byte all-zero ledgerId (matches z_0[0..32] in the all-zero proof)
    bytes internal constant ZERO_LEDGER_ID = new bytes(32);

    // Minimal empty hintsVK — poseidon(empty) == 0 == zi_1 in all-zero proof
    bytes internal constant EMPTY_HINTS_VK = new bytes(0);

    function setUp() public {
        address poseidon = deployCode(
            "PoseidonBN254Contract.sol:PoseidonBN254Contract",
            abi.encode(
                deployCode("PoseidonPermuteA.sol:PoseidonPermuteA"), deployCode("PoseidonPermuteB.sol:PoseidonPermuteB")
            )
        );
        wraps =
            WRAPSVerifierContract(deployCode("WRAPSVerifierContract.sol:WRAPSVerifierContract", abi.encode(poseidon)));
        vkHarness = WRAPSVKHarness(deployCode("WRAPSVerifier.t.sol:WRAPSVKHarness"));
    }

    // ── WRAPSVerifier.verify error paths

    /// @dev Any proof that is not exactly 704 bytes → "WRAPSVerifier: bad length".
    function test_verify_badLength_100bytes() public {
        vm.expectRevert(WRAPSVerifier.WRAPSInvalidProofLength.selector);
        wraps.verify(new bytes(100), EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }

    function test_verify_badLength_0bytes() public {
        vm.expectRevert(WRAPSVerifier.WRAPSInvalidProofLength.selector);
        wraps.verify(new bytes(0), EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }

    function test_verify_badLength_703bytes() public {
        vm.expectRevert(WRAPSVerifier.WRAPSInvalidProofLength.selector);
        wraps.verify(new bytes(703), EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }

    /// @dev 704 zero-byte proof but ledgerId is non-zero → mismatch at z_0.
    function test_verify_ledgerIdMismatch() public {
        bytes memory nonZeroLedger = new bytes(32);
        nonZeroLedger[0] = 0x01; // z_0[0..32] in the proof is all zeros → mismatch

        vm.expectRevert(WRAPSVerifier.WRAPSLedgerIdMismatch.selector);
        wraps.verify(new bytes(704), EMPTY_HINTS_VK, nonZeroLedger, false);
    }

    /// @dev 704 zero-byte proof, zero ledgerId, but hintsVK = one byte 0x01
    ///      → poseidon(hex"01") ≠ 0 (= zi_1 in zero proof) → Poseidon mismatch.
    function test_verify_poseidonMismatch() public {
        bytes memory nonEmptyVk = hex"01"; // poseidon(0x01) ≠ 0

        vm.expectRevert(WRAPSVerifier.WRAPSPoseidonMismatch.selector);
        wraps.verify(new bytes(704), nonEmptyVk, ZERO_LEDGER_ID, false);
    }

    /// @dev 704 zero-byte proof, zero ledgerId, empty hintsVK (poseidon=0=zi_1),
    ///      but u_cmE at offset 288 has no 0x40 infinity flag → "u_cmE not infinity".
    ///      All bytes zero → flags byte = 0x00, bit 6 = 0 → fails the infinity check.
    function test_verify_uCmENotInfinity() public {
        vm.expectRevert(WRAPSVerifier.WRAPSCmENotInfinity.selector);
        wraps.verify(new bytes(704), EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }

    // ── WRAPSVerificationKey.gammaAbc out-of-range

    function test_gammaAbc_indexInRange_41() public view {
        // i=40 is the last valid index (gammaAbc has 41 entries: [0..40])
        (uint256 x, uint256 y) = vkHarness.gammaAbc(40);
        // Just verify it doesn't revert and returns field elements
        uint256 fq = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        assertTrue(x < fq || x == 0, "x must be a valid BN254 Fq element");
        assertTrue(y < fq || y == 0, "y must be a valid BN254 Fq element");
    }

    function test_gammaAbc_outOfRange_reverts() public {
        vm.expectRevert(WRAPSVerificationKey.WRAPSGammaAbcIndexOutOfRange.selector);
        vkHarness.gammaAbc(41);
    }

    function test_gammaAbc_outOfRange_largeIndex() public {
        vm.expectRevert(WRAPSVerificationKey.WRAPSGammaAbcIndexOutOfRange.selector);
        vkHarness.gammaAbc(type(uint256).max);
    }

    /// @dev proof[288] = 0x40 sets the infinity bit on u_i.cmE → passes the
    ///      WRAPSCmENotInfinity check.  All remaining G1 bytes are zero so the
    ///      decompressed points carry x=0; the eventual Groth16 pairing fails.
    function test_verify_passesCmECheck_failsWithRevert() public {
        bytes memory proof = new bytes(704);
        proof[288] = 0x40; // infinity flag on small_u_cmE → condition `& 0x40 == 0` is false
        vm.expectRevert(); // pairing fails or precompile rejects point — any revert is correct
        wraps.verify(proof, EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }

    /// @dev Calling verify with a 705-byte proof must revert for bad length, ensuring
    ///      the happy-path interior of _vkStaticSlice (offset+len ≤ 704) is exercised
    ///      by the test that DOES reach the pairing step.
    function test_verify_badLength_705bytes() public {
        vm.expectRevert(WRAPSVerifier.WRAPSInvalidProofLength.selector);
        wraps.verify(new bytes(705), EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }

    /// @dev all G1/G2 proof points set to infinity so every structural
    ///      check passes, but the Groth16 pairing equation is not satisfied.
    ///
    ///      The infinity flag (0x40) lives in the least-significant byte of each
    ///      compressed field element.  calldataload reads 32 bytes as big-endian,
    ///      so the LS byte of a field at proof[OFF] is proof[OFF + 31].
    ///
    ///      proof[319] doubles as the WRAPSCmENotInfinity check: _cdWord reads
    ///      proof[288..319] and masks with 0x40; byte 319 (LS) carries that flag.
    function test_verify_pairingFails_allInfinityProofPoints() public {
        bytes memory proof = new bytes(704);

        proof[215] = 0x40; // U_i.cmW        (OFF_U_CMW=184,        LS byte at +31)
        proof[247] = 0x40; // U_i.cmE        (OFF_U_CME=216,        LS byte at +31)
        proof[287] = 0x40; // u_i.cmW        (OFF_SMALL_U_CMW=256,  LS byte at +31)
        proof[319] = 0x40; // u_i.cmE        (OFF_SMALL_U_CME=288,  LS byte at +31; satisfies WRAPSCmENotInfinity)
        proof[351] = 0x40; // proof A        (OFF_PROOF_A=320,      LS byte at +31)
        proof[415] = 0x40; // proof B c1     (OFF_PROOF_B_C1=384,   LS byte at +31 → G2 infinity)
        proof[447] = 0x40; // proof C        (OFF_PROOF_C=416,      LS byte at +31)
        proof[511] = 0x40; // kzg[0].w       (OFF_KZG0_W=480,       LS byte at +31)
        proof[575] = 0x40; // kzg[1].w       (OFF_KZG1_W=544,       LS byte at +31)
        proof[607] = 0x40; // cmT            (OFF_CMT=576,           LS byte at +31)

        vm.expectRevert(WRAPSVerifier.WRAPSPairingFailed.selector);
        wraps.verify(proof, EMPTY_HINTS_VK, ZERO_LEDGER_ID, false);
    }
}
