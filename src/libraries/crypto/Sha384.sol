// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Sha384
/// @notice Pure Solidity implementation of SHA-384 (48-byte truncation of SHA-512).
/// @dev Used by the Hiero Merkle proof verifier which requires SHA-384 for path hashing.
///      The 80-round compression function is fully inlined in Yul to avoid EVM stack-too-deep.
library Sha384 {
    /// @notice Compute the SHA-384 hash of `data`.
    /// @param data Arbitrary-length input bytes.
    /// @return out The 48-byte SHA-384 digest.
    function hash(bytes memory data) internal pure returns (bytes memory out) {
        uint64[8] memory h = [
            uint64(0xcbbb9d5dc1059ed8),
            uint64(0x629a292a367cd507),
            uint64(0x9159015a3070dd17),
            uint64(0x152fecd8f70e5939),
            uint64(0x67332667ffc00b31),
            uint64(0x8eb44a8768581511),
            uint64(0xdb0c2e0d64f98fa7),
            uint64(0x47b5481dbefa4fa4)
        ];
        _digest(data, h);
        out = new bytes(48);
        _write64(out, 0, h[0]);
        _write64(out, 8, h[1]);
        _write64(out, 16, h[2]);
        _write64(out, 24, h[3]);
        _write64(out, 32, h[4]);
        _write64(out, 40, h[5]);
    }

    function _digest(bytes memory data, uint64[8] memory h) private pure {
        uint256 dataLen = data.length;
        uint256 bitLen;
        unchecked {
            bitLen = dataLen * 8;
        }
        uint256 paddedLen = dataLen + 17;
        uint256 rem = paddedLen % 128;

        // forgefmt: disable-next-line
        if (rem != 0) { unchecked { paddedLen += 128 - rem; } }

        bytes memory m = new bytes(paddedLen);
        // Word-aligned copy. Solidity zero-pads allocations to 32-byte boundaries,
        // so reading up to 31 bytes past dataLen in `data` always yields zeros.
        assembly ("memory-safe") {
            let src := add(data, 32)
            let dst := add(m, 32)
            for { let i := 0 } lt(i, dataLen) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
        m[dataLen] = 0x80;
        _write64(m, paddedLen - 16, 0);
        _write64(m, paddedLen - 8, SafeCast.toUint64(bitLen));

        assembly ("memory-safe") {
            let M64 := 0xFFFFFFFFFFFFFFFF

            // Scratch layout from the free pointer: K[80] | W[80] | V[8].
            // K (round constants) is written once and reused for every block.
            let kPtr := mload(0x40)
            let wPtr := add(kPtr, 0xa00) // 80 * 32
            let vPtr := add(wPtr, 0xa00)
            mstore(0x40, add(vPtr, 0x100)) // reserve 8 * 32 for V
            mstore(add(kPtr, 0x0), 0x428a2f98d728ae22)
            mstore(add(kPtr, 0x20), 0x7137449123ef65cd)
            mstore(add(kPtr, 0x40), 0xb5c0fbcfec4d3b2f)
            mstore(add(kPtr, 0x60), 0xe9b5dba58189dbbc)
            mstore(add(kPtr, 0x80), 0x3956c25bf348b538)
            mstore(add(kPtr, 0xa0), 0x59f111f1b605d019)
            mstore(add(kPtr, 0xc0), 0x923f82a4af194f9b)
            mstore(add(kPtr, 0xe0), 0xab1c5ed5da6d8118)
            mstore(add(kPtr, 0x100), 0xd807aa98a3030242)
            mstore(add(kPtr, 0x120), 0x12835b0145706fbe)
            mstore(add(kPtr, 0x140), 0x243185be4ee4b28c)
            mstore(add(kPtr, 0x160), 0x550c7dc3d5ffb4e2)
            mstore(add(kPtr, 0x180), 0x72be5d74f27b896f)
            mstore(add(kPtr, 0x1a0), 0x80deb1fe3b1696b1)
            mstore(add(kPtr, 0x1c0), 0x9bdc06a725c71235)
            mstore(add(kPtr, 0x1e0), 0xc19bf174cf692694)
            mstore(add(kPtr, 0x200), 0xe49b69c19ef14ad2)
            mstore(add(kPtr, 0x220), 0xefbe4786384f25e3)
            mstore(add(kPtr, 0x240), 0x0fc19dc68b8cd5b5)
            mstore(add(kPtr, 0x260), 0x240ca1cc77ac9c65)
            mstore(add(kPtr, 0x280), 0x2de92c6f592b0275)
            mstore(add(kPtr, 0x2a0), 0x4a7484aa6ea6e483)
            mstore(add(kPtr, 0x2c0), 0x5cb0a9dcbd41fbd4)
            mstore(add(kPtr, 0x2e0), 0x76f988da831153b5)
            mstore(add(kPtr, 0x300), 0x983e5152ee66dfab)
            mstore(add(kPtr, 0x320), 0xa831c66d2db43210)
            mstore(add(kPtr, 0x340), 0xb00327c898fb213f)
            mstore(add(kPtr, 0x360), 0xbf597fc7beef0ee4)
            mstore(add(kPtr, 0x380), 0xc6e00bf33da88fc2)
            mstore(add(kPtr, 0x3a0), 0xd5a79147930aa725)
            mstore(add(kPtr, 0x3c0), 0x06ca6351e003826f)
            mstore(add(kPtr, 0x3e0), 0x142929670a0e6e70)
            mstore(add(kPtr, 0x400), 0x27b70a8546d22ffc)
            mstore(add(kPtr, 0x420), 0x2e1b21385c26c926)
            mstore(add(kPtr, 0x440), 0x4d2c6dfc5ac42aed)
            mstore(add(kPtr, 0x460), 0x53380d139d95b3df)
            mstore(add(kPtr, 0x480), 0x650a73548baf63de)
            mstore(add(kPtr, 0x4a0), 0x766a0abb3c77b2a8)
            mstore(add(kPtr, 0x4c0), 0x81c2c92e47edaee6)
            mstore(add(kPtr, 0x4e0), 0x92722c851482353b)
            mstore(add(kPtr, 0x500), 0xa2bfe8a14cf10364)
            mstore(add(kPtr, 0x520), 0xa81a664bbc423001)
            mstore(add(kPtr, 0x540), 0xc24b8b70d0f89791)
            mstore(add(kPtr, 0x560), 0xc76c51a30654be30)
            mstore(add(kPtr, 0x580), 0xd192e819d6ef5218)
            mstore(add(kPtr, 0x5a0), 0xd69906245565a910)
            mstore(add(kPtr, 0x5c0), 0xf40e35855771202a)
            mstore(add(kPtr, 0x5e0), 0x106aa07032bbd1b8)
            mstore(add(kPtr, 0x600), 0x19a4c116b8d2d0c8)
            mstore(add(kPtr, 0x620), 0x1e376c085141ab53)
            mstore(add(kPtr, 0x640), 0x2748774cdf8eeb99)
            mstore(add(kPtr, 0x660), 0x34b0bcb5e19b48a8)
            mstore(add(kPtr, 0x680), 0x391c0cb3c5c95a63)
            mstore(add(kPtr, 0x6a0), 0x4ed8aa4ae3418acb)
            mstore(add(kPtr, 0x6c0), 0x5b9cca4f7763e373)
            mstore(add(kPtr, 0x6e0), 0x682e6ff3d6b2b8a3)
            mstore(add(kPtr, 0x700), 0x748f82ee5defb2fc)
            mstore(add(kPtr, 0x720), 0x78a5636f43172f60)
            mstore(add(kPtr, 0x740), 0x84c87814a1f0ab72)
            mstore(add(kPtr, 0x760), 0x8cc702081a6439ec)
            mstore(add(kPtr, 0x780), 0x90befffa23631e28)
            mstore(add(kPtr, 0x7a0), 0xa4506cebde82bde9)
            mstore(add(kPtr, 0x7c0), 0xbef9a3f7b2c67915)
            mstore(add(kPtr, 0x7e0), 0xc67178f2e372532b)
            mstore(add(kPtr, 0x800), 0xca273eceea26619c)
            mstore(add(kPtr, 0x820), 0xd186b8c721c0c207)
            mstore(add(kPtr, 0x840), 0xeada7dd6cde0eb1e)
            mstore(add(kPtr, 0x860), 0xf57d4f7fee6ed178)
            mstore(add(kPtr, 0x880), 0x06f067aa72176fba)
            mstore(add(kPtr, 0x8a0), 0x0a637dc5a2c898a6)
            mstore(add(kPtr, 0x8c0), 0x113f9804bef90dae)
            mstore(add(kPtr, 0x8e0), 0x1b710b35131c471b)
            mstore(add(kPtr, 0x900), 0x28db77f523047d84)
            mstore(add(kPtr, 0x920), 0x32caab7b40c72493)
            mstore(add(kPtr, 0x940), 0x3c9ebe0a15c9bebc)
            mstore(add(kPtr, 0x960), 0x431d67c49c100d4c)
            mstore(add(kPtr, 0x980), 0x4cc5d4becb3e42b6)
            mstore(add(kPtr, 0x9a0), 0x597f299cfc657e2a)
            mstore(add(kPtr, 0x9c0), 0x5fcb6fab3ad6faec)
            mstore(add(kPtr, 0x9e0), 0x6c44198c4a475817)
            let mBase := add(m, 32)
            let mLen := mload(m)

            for { let off := 0 } lt(off, mLen) { off := add(off, 128) } {
                let blk := add(mBase, off)

                for { let i := 0 } lt(i, 16) { i := add(i, 1) } {
                    mstore(add(wPtr, shl(5, i)), shr(192, mload(add(blk, mul(i, 8)))))
                }

                for { let i := 16 } lt(i, 80) { i := add(i, 1) } {
                    let w2 := mload(add(wPtr, shl(5, sub(i, 2))))
                    let w15 := mload(add(wPtr, shl(5, sub(i, 15))))
                    // smallSigma1(w2) = ROTR(19)^ROTR(61)^SHR(6)
                    let s1 := and(xor(xor(or(shr(19, w2), shl(45, w2)), or(shr(61, w2), shl(3, w2))), shr(6, w2)), M64)
                    // smallSigma0(w15) = ROTR(1)^ROTR(8)^SHR(7)
                    let s0 :=
                        and(xor(xor(or(shr(1, w15), shl(63, w15)), or(shr(8, w15), shl(56, w15))), shr(7, w15)), M64)
                    let wv :=
                        and(
                            add(
                                add(add(s1, mload(add(wPtr, shl(5, sub(i, 7))))), s0),
                                mload(add(wPtr, shl(5, sub(i, 16))))
                            ),
                            M64
                        )
                    mstore(add(wPtr, shl(5, i)), wv)
                }

                // v ← h
                for { let j := 0 } lt(j, 0x100) { j := add(j, 0x20) } {
                    mstore(add(vPtr, j), mload(add(h, j)))
                }

                // t1 = vh + BigSigma1(ve) + Ch(ve,vf,vg) + k[i] + w[i]
                // Scoped to cap peak live vars: outer(M64,v,k,w,i,t2 placeholder) +
                // inner(ve,vf,vg,vh,ki,wi,s1,ch) = ≤14 total
                for { let i := 0 } lt(i, 80) { i := add(i, 1) } {
                    let t1 := 0
                    {
                        let ve := mload(add(vPtr, 0x80))
                        let vf := mload(add(vPtr, 0xa0))
                        let vg := mload(add(vPtr, 0xc0))
                        let vh := mload(add(vPtr, 0xe0))
                        // BigSigma1: ROTR(e,14)^ROTR(e,18)^ROTR(e,41), one AND masks all
                        let s1 :=
                            and(
                                xor(
                                    xor(or(shr(14, ve), shl(50, ve)), or(shr(18, ve), shl(46, ve))),
                                    or(shr(41, ve), shl(23, ve))
                                ),
                                M64
                            )
                        // Ch(e,f,g) = g ^ (e & (f^g))
                        let ch := xor(vg, and(ve, xor(vf, vg)))
                        t1 := and(
                            add(add(add(add(vh, s1), ch), mload(add(kPtr, shl(5, i)))), mload(add(wPtr, shl(5, i)))),
                            M64
                        )
                    }

                    // t2 = BigSigma0(va) + Maj(va,vb,vc)
                    let t2 := 0
                    {
                        let va := mload(vPtr)
                        let vb := mload(add(vPtr, 0x20))
                        let vc := mload(add(vPtr, 0x40))
                        // BigSigma0: ROTR(a,28)^ROTR(a,34)^ROTR(a,39)
                        let s0 :=
                            and(
                                xor(
                                    xor(or(shr(28, va), shl(36, va)), or(shr(34, va), shl(30, va))),
                                    or(shr(39, va), shl(25, va))
                                ),
                                M64
                            )
                        // Maj(a,b,c) = (a&b)|(c&(a^b))
                        let maj := or(and(va, vb), and(vc, xor(va, vb)))
                        t2 := add(s0, maj)
                    }

                    // State rotation (high→low address order avoids aliasing)
                    mstore(add(vPtr, 0xe0), mload(add(vPtr, 0xc0)))
                    mstore(add(vPtr, 0xc0), mload(add(vPtr, 0xa0)))
                    mstore(add(vPtr, 0xa0), mload(add(vPtr, 0x80)))
                    mstore(add(vPtr, 0x80), and(add(mload(add(vPtr, 0x60)), t1), M64))
                    mstore(add(vPtr, 0x60), mload(add(vPtr, 0x40)))
                    mstore(add(vPtr, 0x40), mload(add(vPtr, 0x20)))
                    mstore(add(vPtr, 0x20), mload(vPtr))
                    mstore(vPtr, and(add(t1, t2), M64))
                }

                // ── H[i] += V[i] ────────────────────────────────────────────
                for { let j := 0 } lt(j, 0x100) { j := add(j, 0x20) } {
                    mstore(add(h, j), and(add(mload(add(h, j)), mload(add(vPtr, j))), M64))
                }
            }

            // Reclaim digest-internal scratch (`m` upward). `m` was allocated at the
            // free pointer on entry, so its own pointer is the value to restore; `h`
            // sits below `m` and is untouched. Prevents quadratic memory growth when
            // many hashes run back-to-back (e.g. a Merkle walk).
            mstore(0x40, m)
        }
    }

    /// @dev Write uint64 x as big-endian 8 bytes at b[off..off+7].
    ///      off is always a multiple of 8; the 8 bytes fit in one 32-byte EVM slot.
    function _write64(bytes memory b, uint256 off, uint64 x) private pure {
        assembly ("memory-safe") {
            let ptr := add(add(b, 32), off)
            let slot := and(ptr, not(0x1f))
            let byteOff := and(ptr, 0x1f) // 0, 8, 16, or 24 for our call sites
            switch byteOff
            case 0 {
                let mask := 0x0000000000000000ffffffffffffffffffffffffffffffffffffffffffffffff
                mstore(slot, or(and(mload(slot), mask), shl(192, x)))
            }
            case 8 {
                let mask := 0xffffffffffffffff0000000000000000ffffffffffffffffffffffffffffffff
                mstore(slot, or(and(mload(slot), mask), shl(128, x)))
            }
            case 16 {
                let mask := 0xffffffffffffffffffffffffffffffff0000000000000000ffffffffffffffff
                mstore(slot, or(and(mload(slot), mask), shl(64, x)))
            }
            default {
                let mask := 0xffffffffffffffffffffffffffffffffffffffffffffffff0000000000000000
                mstore(slot, or(and(mload(slot), mask), x))
            }
        }
    }
}
