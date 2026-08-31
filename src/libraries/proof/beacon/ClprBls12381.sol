// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title ClprBls12381
/// @notice Minimal BLS12-381 G1 *compression* (uncompressed → 48-byte ZCash/Ethereum compressed).
///
/// @dev Used by the Ethereum sync-committee verifier to recompute the SSZ committee root from the
///      uncompressed pubkeys at rotation: the beacon `SyncCommittee` root commits to the 48-byte
///      compressed encoding, and compression is the cheap direction (no field square root — just read
///      the y sign bit). On-chain *decompression* is gas-infeasible and deliberately avoided: the
///      relayer supplies uncompressed points (see ClprBeaconBls / the ethereum README).
///
/// @dev A field element is carried as `(hi, lo)` = `hi·2^256 + lo` (`hi < 2^128`).
/// @dev Consensus-critical, hand-rolled crypto: validated against the BLS12-381 G1 generator vector.
library ClprBls12381 {
    // (p-1)/2 — a y coordinate is "negative" (sign bit set) iff it is > (p-1)/2.
    uint256 internal constant P_HALF_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 internal constant P_HALF_LO = 0xb23ba5c279d2fadf3b3986a07b587b3120f5ffff58a9ffffdcff7fffffffd555;

    // Compressed-point flag bits (most-significant byte).
    uint8 internal constant FLAG_COMPRESSED = 0x80;
    uint8 internal constant FLAG_INFINITY = 0x40;
    uint8 internal constant FLAG_SIGN = 0x20;

    error BadLength();

    /// @dev a > b, 384-bit unsigned.
    function _gt(uint256 aHi, uint256 aLo, uint256 bHi, uint256 bLo) internal pure returns (bool) {
        if (aHi != bHi) return aHi > bHi;
        return aLo > bLo;
    }

    /// @dev 48-byte big-endian encoding of `hi·2^256 + lo`.
    function _toBytes48(uint256 hi, uint256 lo) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return abi.encodePacked(bytes16(uint128(hi)), bytes32(lo)); // hi < 2^128 by construction
    }

    /// @notice Compress a 128-byte EIP-2537 G1 point (`pad16||x(48)||pad16||y(48)`) into the 48-byte
    ///         ZCash/Ethereum compressed encoding. The cheap direction (no field square root) — used
    ///         to recompute the SSZ sync-committee root from uncompressed pubkeys at rotation.
    function compressG1(bytes memory uncompressed) internal pure returns (bytes memory) {
        if (uncompressed.length != 128) revert BadLength();
        uint256 xHi;
        uint256 xLo;
        uint256 yHi;
        uint256 yLo;
        assembly ("memory-safe") {
            xHi := mload(add(uncompressed, 0x20)) // bytes[0..32): pad16 || x-top16  → x-top16
            xLo := mload(add(uncompressed, 0x40)) // bytes[32..64): x-low32
            yHi := mload(add(uncompressed, 0x60)) // bytes[64..96): pad16 || y-top16 → y-top16
            yLo := mload(add(uncompressed, 0x80)) // bytes[96..128): y-low32
        }
        if (xHi == 0 && xLo == 0 && yHi == 0 && yLo == 0) {
            bytes memory inf = new bytes(48);
            inf[0] = bytes1(FLAG_COMPRESSED | FLAG_INFINITY);
            return inf;
        }
        // sign bit: y is "negative" iff y > (p-1)/2.
        uint8 flags = FLAG_COMPRESSED | (_gt(yHi, yLo, P_HALF_HI, P_HALF_LO) ? FLAG_SIGN : 0);
        bytes memory out = _toBytes48(xHi, xLo);
        out[0] = bytes1(uint8(out[0]) | flags); // x < p ⇒ its top 3 bits are clear
        return out;
    }
}
