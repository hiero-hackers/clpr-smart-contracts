// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {ClprBeaconBls} from "@hiero-ledger/clpr/libraries/proof/beacon/ClprBeaconBls.sol";
import {ClprBeaconSsz} from "@hiero-ledger/clpr/libraries/proof/beacon/ClprBeaconSsz.sol";
import {EthCommitteeFixtures} from "@test/verifiers/evm/ethereum/EthCommitteeFixtures.sol";

/// @notice Gas benchmark for the Ethereum mainnet verifier's on-chain BLS12-381 / SSZ hot paths
///         (EIP-2537 precompiles). These dominate `EthMainnetVerifier.verifyBundle`.
///
/// Uses the SELF-CONSISTENT generator committee from {EthCommitteeFixtures} so no live beacon
/// devnet / committed fixture is needed: the on-chain aggregate of N members is N·G1 and the
/// matching aggregate signature is N·H(signingRoot) (built via the G2MSM precompile). The pairing
/// e(N·G1, H)·e(-G1, N·H) == 1 holds for any N, so verification succeeds and the measured gas is
/// the real success-path cost. A full `verifyBundle` benchmark would additionally need committed
/// MPT/SSZ fixtures (the e2e specs exercise that path).
///
/// Each metric lives in its OWN test so it is measured against fresh EVM memory — measuring several in
/// one function inflates the later ones (memory-expansion gas grows with the high-water mark), which
/// would also understate the complement path's savings. The `BLS aggregateVerifyComplement` numbers are
/// the production path (`EthMainnetVerifier._verifyBls`).
contract EthMainnetVerifierGasBenchmarkTest is EthCommitteeFixtures {
    bytes32 internal constant SIGNING_ROOT = bytes32(uint256(0x1234));

    /// hash-to-G2 of the signing root (RFC 9380 expand + 2× MAP_FP2_TO_G2 + G2ADD).
    function test_gas_hashToG2() public view {
        uint256 g0 = gasleft();
        ClprBeaconBls.hashToG2(SIGNING_ROOT);
        console.log("hashToG2:", g0 - gasleft());
    }

    // ── Production complement path (EthMainnetVerifier._verifyBls) ────────────────
    //  participant aggregate = committeeAggregate − Σ(non-participants), folded into ONE G1MSM. At the
    //  supermajority this is 1 + 170 terms instead of 342, and at full participation it skips the MSM
    //  entirely (the aggregate is the participant aggregate). Cost scales with the NON-signer count, so
    //  the common high-participation case is the cheapest.

    /// Complement path at the 2/3 supermajority: 170 non-participants subtracted from the aggregate.
    function test_gas_bls_complement_342() public view {
        bytes memory aggregate = _committeeAggregate(); // authenticated 512·G1
        bytes memory sig342 = _aggSig(SIGNING_ROOT, SUPERMAJORITY);
        bytes[] memory nonP170 = _uncompressedKeys(SYNC_COMMITTEE_SIZE - SUPERMAJORITY);
        uint256 g0 = gasleft();
        ClprBeaconBls.aggregateVerifyComplement(aggregate, nonP170, sig342, SIGNING_ROOT);
        console.log("BLS aggregateVerifyComplement 342 (170 nonP):", g0 - gasleft());
    }

    /// Complement path at full participation: zero non-participants, aggregate used directly (no MSM).
    function test_gas_bls_complement_512() public view {
        bytes memory aggregate = _committeeAggregate();
        bytes memory sig512 = _aggSig(SIGNING_ROOT, SYNC_COMMITTEE_SIZE);
        bytes[] memory nonP0 = new bytes[](0);
        uint256 g0 = gasleft();
        ClprBeaconBls.aggregateVerifyComplement(aggregate, nonP0, sig512, SIGNING_ROOT);
        console.log("BLS aggregateVerifyComplement 512 (0 nonP):", g0 - gasleft());
    }

    /// Rotation SSZ committee root, production path: from the 512 uncompressed pubkeys + aggregate,
    /// compressing each on the fly (`EthMainnetVerifier._verifyRotation`).
    function test_gas_ssz_committeeRoot() public view {
        bytes[] memory keys = _uncompressedKeys(SYNC_COMMITTEE_SIZE);
        uint256 g0 = gasleft();
        ClprBeaconSsz.syncCommitteeRootFromUncompressed(keys, genUncompressed);
        console.log("SSZ syncCommitteeRootFromUncompressed 512:", g0 - gasleft());
    }
}
