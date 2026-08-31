// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

interface IPoseidonPermute {
    function permute(uint256 s0, uint256 s1, uint256 s2, uint256 s3, uint256 s4)
        external
        pure
        returns (uint256, uint256, uint256, uint256, uint256);
}

/// @notice Deployed Poseidon-BN254 hasher.
///         The 68-round permutation is split across two deployed contracts
///         (PoseidonPermuteA: rounds 0-33, PoseidonPermuteB: rounds 34-67),
///         each within the EIP-170 24 576-byte deployed-bytecode limit.
///         Within each split, the MDS matrix is extracted into a shared private
///         `_mds()` subroutine so the Yul optimizer keeps one copy per contract.
contract PoseidonBN254Contract {
    uint256 private constant FR = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IPoseidonPermute public immutable PERMUTE_A;
    IPoseidonPermute public immutable PERMUTE_B;

    constructor(address a, address b) {
        PERMUTE_A = IPoseidonPermute(a);
        PERMUTE_B = IPoseidonPermute(b);
    }

    /// @notice Hash hintsVk bytes exactly as Rust hash_hints_vk(): chunk into 32-byte LE Fr
    ///         elements, absorb with Poseidon sponge (rate=4, capacity=1), return state[1].
    function hashHintsVk(bytes calldata hintsVk) external view returns (uint256) {
        uint256 n = (hintsVk.length + 31) / 32;
        uint256 s0 = 0;
        uint256 s1 = 0;
        uint256 s2 = 0;
        uint256 s3 = 0;
        uint256 s4 = 0;
        uint256 absorbIdx = 0;

        for (uint256 chunk = 0; chunk < n; chunk++) {
            uint256 start = chunk * 32;
            uint256 end = start + 32 < hintsVk.length ? start + 32 : hintsVk.length;
            uint256 elem = _readLeFr(hintsVk, start, end);

            if (absorbIdx == 0) s1 = addmod(s1, elem, FR);
            else if (absorbIdx == 1) s2 = addmod(s2, elem, FR);
            else if (absorbIdx == 2) s3 = addmod(s3, elem, FR);
            else s4 = addmod(s4, elem, FR);
            absorbIdx++;

            if (absorbIdx == 4) {
                (s0, s1, s2, s3, s4) = _permute(s0, s1, s2, s3, s4);
                absorbIdx = 0;
            }
        }

        if (absorbIdx != 0) {
            (s0, s1, s2, s3, s4) = _permute(s0, s1, s2, s3, s4);
        }

        return s1;
    }

    function _permute(uint256 s0, uint256 s1, uint256 s2, uint256 s3, uint256 s4)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        (s0, s1, s2, s3, s4) = PERMUTE_A.permute(s0, s1, s2, s3, s4);
        (s0, s1, s2, s3, s4) = PERMUTE_B.permute(s0, s1, s2, s3, s4);
        return (s0, s1, s2, s3, s4);
    }

    function _readLeFr(bytes calldata data, uint256 start, uint256 end) private pure returns (uint256) {
        uint256 raw;
        assembly { raw := calldataload(add(data.offset, start)) }
        uint256 val = _bswap32(raw);
        uint256 len = end - start;
        if (len < 32) {
            val &= type(uint256).max >> ((32 - len) * 8);
        }
        return val % FR;
    }

    function _bswap32(uint256 x) private pure returns (uint256 result) {
        assembly {
            result := x
            result := or(
                and(shr(8, result), 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF),
                and(shl(8, result), 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00)
            )
            result := or(
                and(shr(16, result), 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF),
                and(shl(16, result), 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000)
            )
            result := or(
                and(shr(32, result), 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF),
                and(shl(32, result), 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000)
            )
            result := or(
                and(shr(64, result), 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF),
                and(shl(64, result), 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000)
            )
            result := or(shr(128, result), shl(128, result))
        }
    }
}
