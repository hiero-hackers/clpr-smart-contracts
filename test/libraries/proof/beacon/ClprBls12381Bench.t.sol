// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ClprBls12381} from "@hiero-ledger/clpr/libraries/proof/beacon/ClprBls12381.sol";

/// Gas benchmark for on-chain BLS12-381 G1 pubkey *compression* (uncompressed → compressed) — the
/// cheap, pure direction (no MODEXP) used to rebuild the SSZ sync-committee root at rotation. On-chain
/// *decompression* is intentionally not implemented (it is gas-infeasible: ~41k/key, ~22.8M for 512 G1,
/// and ~49.5M for a single G2), so the relayer supplies uncompressed points instead.
contract ClprBls12381BenchHarness {
    function compressG1(bytes memory uncompressed) external pure returns (bytes memory) {
        return ClprBls12381.compressG1(uncompressed);
    }

    /// Compress the same point `n` times (the cheap, pure direction — no MODEXP).
    function compressMany(bytes memory uncompressed, uint256 n) external pure returns (uint256) {
        uint256 acc;
        for (uint256 i = 0; i < n; i++) {
            bytes memory out = ClprBls12381.compressG1(uncompressed);
            acc += out.length; // prevent the call from being optimized away
        }
        return acc;
    }
}

contract ClprBls12381BenchTest is Test {
    ClprBls12381BenchHarness harness;

    // A real compressed G1 sync-committee pubkey (generated with @noble/curves).
    bytes constant COMPRESSED_PUBKEY =
        hex"9986d6faa2e15a0b41c2281c4773667210e9c3513534115d3ac5ee173cdea619df5cc4c84a42ec61d538ba6bb7939871";
    // The same pubkey in EIP-2537 uncompressed (128-byte) form.
    bytes constant UNCOMPRESSED_PUBKEY = hex"000000000000000000000000000000001986d6faa2e15a0b41c2281c4773667210e9c3513534115d3ac5ee173cdea619df5cc4c84a42ec61d538ba6bb7939871"
        hex"00000000000000000000000000000000027e908c2240dc29f5bcca4da61e90f34fe1d3ad5cf810fc38ac6707b2642fd3c1d18109067aaec19d4fdd9a4f0cd63d";

    uint256 constant COMMITTEE_SIZE = 512;

    function setUp() public {
        harness = new ClprBls12381BenchHarness();
    }

    function test_compressG1_isCorrect() public view {
        bytes memory out = harness.compressG1(UNCOMPRESSED_PUBKEY);
        assertEq(out.length, 48, "compressed length");
        assertEq(keccak256(out), keccak256(COMPRESSED_PUBKEY), "round-trips to the known compressed pubkey");
    }

    function test_gas_compress_marginal() public view {
        uint256 g1start = gasleft();
        harness.compressMany(UNCOMPRESSED_PUBKEY, 1);
        uint256 cost1 = g1start - gasleft();

        uint256 g2start = gasleft();
        harness.compressMany(UNCOMPRESSED_PUBKEY, 11);
        uint256 cost11 = g2start - gasleft();

        uint256 perKey = (cost11 - cost1) / 10;
        console.log("G1 compress, marginal per-key gas:", perKey);
        console.log("  -> x512 committee:", perKey * COMMITTEE_SIZE);
        console.log("  -> x513 committee+aggregate (rotation SSZ root):", perKey * (COMMITTEE_SIZE + 1));
    }

    function test_gas_compress_single() public view {
        uint256 g0 = gasleft();
        harness.compressG1(UNCOMPRESSED_PUBKEY);
        uint256 used = g0 - gasleft();
        console.log("G1 compress, single call (incl. external call overhead):", used);
    }

    function test_gas_compress_513() public view {
        uint256 g0 = gasleft();
        harness.compressMany(UNCOMPRESSED_PUBKEY, COMMITTEE_SIZE + 1);
        uint256 used = g0 - gasleft();
        console.log("G1 compress x513 (one tx, measured):", used);
    }
}
