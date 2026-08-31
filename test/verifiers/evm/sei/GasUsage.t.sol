// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SeiCometBftVerifier} from "@hiero-ledger/clpr/verifiers/evm/sei/SeiCometBftVerifier.sol";
import {Ed25519Verifier} from "@hiero-ledger/clpr/verifiers/evm/sei/Ed25519Verifier.sol";
import {SeiRealBundleFixtures} from "@test/verifiers/evm/sei/SeiRealBundleFixtures.sol";
import {CometBftLib} from "@hiero-ledger/clpr/libraries/proof/cometbft/CometBftLib.sol";
import {Ics23Lib} from "@hiero-ledger/clpr/libraries/proof/cometbft/Ics23Lib.sol";

/// @dev Exposes the verifier internals and measures per-step gas with `gasleft()` deltas, all inside
///      a single call so there is no inter-step external-call overhead. Uses the REAL relay bundle
///      data captured from clpr-relay-sei1 (see SeiRealBundle.t.sol): a genuine signed header, a
///      genuine Ed25519 signature verified by the pure-Solidity {Ed25519Verifier}, and a genuine
///      ICS-23 IAVL non-existence storage proof.
contract SeiGasHarness is SeiCometBftVerifier {
    constructor(address ed) SeiCometBftVerifier(ed) {}

    /// @notice Measures the signed-header verification path (steps 1–3 of _verifyStateProof) plus the
    ///         protobuf parse, for a 1-validator / 1-signature commit. Returns the per-signature
    ///         Ed25519 cost so the caller can extrapolate to larger validator sets.
    function measureSignedHeader(bytes memory signedHeader, bytes32 pubkey, int64 power, bytes memory sig)
        external
        view
        returns (uint256 edPerSig, uint256 signedHeaderTotal)
    {
        uint256 g;

        g = gasleft();
        (CometBftLib.SeiHeader memory hdr, CometBftLib.SeiCommit memory c) = _parseSignedHeader(signedHeader);
        uint256 gParse = g - gasleft();
        console2.log("parseSignedHeader (proto) :", gParse);

        CometBftLib.SeiValidator[] memory vs = new CometBftLib.SeiValidator[](1);
        vs[0] = CometBftLib.SeiValidator({ed25519PubKey: pubkey, votingPower: power});
        g = gasleft();
        CometBftLib.validatorSetHash(vs);
        uint256 gVsh = g - gasleft();
        console2.log("S1 validatorSetHash       :", gVsh);

        g = gasleft();
        bytes32 hh = CometBftLib.headerHash(hdr);
        uint256 gHh = g - gasleft();
        console2.log("S2 headerHash (14 fields) :", gHh);

        g = gasleft();
        bytes memory sb = CometBftLib.precommitSignBytes(
            hdr.chainId,
            hdr.height,
            c.round,
            hh,
            c.partSetTotal,
            c.partSetHash,
            c.signatures[0].timestampSeconds,
            c.signatures[0].timestampNanos
        );
        uint256 gSb = g - gasleft();
        console2.log("S3 precommitSignBytes     :", gSb);

        g = gasleft();
        bool ok = _verifyEd25519(pubkey, sb, sig);
        edPerSig = g - gasleft();
        console2.log("S3 ed25519 verify PER SIG :", edPerSig);
        require(ok, "ed25519 verify failed on real data");

        signedHeaderTotal = gParse + gVsh + gHh + gSb + edPerSig;
        console2.log("signed-header path TOTAL  :", signedHeaderTotal);
    }

    /// @notice Measures one storage-slot ICS-23 IAVL proof (the non-existence case captured from sei1).
    ///         An existence proof is the same shape (parse + one root recomputation) minus the
    ///         second neighbour, so this is a representative per-slot figure.
    function measureIavlProof(bytes memory commitmentProof, bytes memory key) external view returns (uint256 perSlot) {
        uint256 g = gasleft();
        (bool isExist,, Ics23Lib.NonExistenceProof memory nep) = _parseCommitmentProof(commitmentProof);
        uint256 gParse = g - gasleft();
        require(!isExist, "expected non-existence proof");
        console2.log("parseCommitmentProof      :", gParse);

        g = gasleft();
        bytes32 root = Ics23Lib.existenceRootIavl(nep.left);
        uint256 gRoot = g - gasleft();
        console2.log("existenceRootIavl (1 leaf):", gRoot);

        g = gasleft();
        Ics23Lib.verifyNonMembershipIavl(nep, root, key);
        uint256 gVerify = g - gasleft();
        console2.log("verifyNonMembershipIavl   :", gVerify);

        perSlot = gParse + gRoot + gVerify;
        console2.log("per-slot IAVL proof TOTAL :", perSlot);
    }
}

/// @notice Gas usage benchmark for the Sei CometBFT verifier, driven by the real captured relay
///         data in {SeiRealBundleFixtures}.
contract SeiGasBenchmarkTest is Test, SeiRealBundleFixtures {
    SeiGasHarness internal harness;

    function setUp() public {
        Ed25519Verifier ed = new Ed25519Verifier();
        CometBftLib.SeiValidator[] memory gv = new CometBftLib.SeiValidator[](1);
        gv[0] = CometBftLib.SeiValidator({ed25519PubKey: PUBKEY, votingPower: POWER});
        harness = new SeiGasHarness(address(ed));
    }

    function test_sei_verifier_gas_breakdown() public view {
        console2.log("=== Sei CometBFT Verifier Gas Breakdown (real relay data) ===");
        console2.log("--- Signed-header verification (per commit; Ed25519 is per-signature) ---");
        (uint256 edPerSig, uint256 signedHeaderTotal) = harness.measureSignedHeader(SIGNED_HEADER, PUBKEY, POWER, SIG);

        console2.log("--- Storage proof (ICS-23 IAVL, per slot) ---");
        uint256 perSlot = harness.measureIavlProof(IAVL_PROOF, ABSENT_KEY);

        // Extrapolated full-bundle estimate. A message-bearing bundle proves 1 multistore membership
        // proof + 5 storage slots, and _verifyCommit runs one Ed25519 verify per signing validator.
        // We approximate the multistore proof as one per-slot figure (same ICS-23 machinery).
        console2.log("--- Extrapolated verifyBundle (fixed = header path + 6 ICS-23 proofs) ---");
        uint256 fixedCost = signedHeaderTotal - edPerSig + 6 * perSlot;
        console2.log("fixed cost (excl. sigs)   :", fixedCost);
        uint8[6] memory ns = [1, 4, 10, 40, 50, 100];
        for (uint256 i = 0; i < ns.length; i++) {
            console2.log("validators (all signing)  :", uint256(ns[i]));
            console2.log("  approx verifyBundle gas :", fixedCost + uint256(ns[i]) * edPerSig);
        }
    }
}
