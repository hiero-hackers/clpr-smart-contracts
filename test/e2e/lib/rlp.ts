import {RLP, type Input, type NestedUint8Array} from "@ethereumjs/rlp";

/// Shared RLP helpers for e2e proof construction, built on `@ethereumjs/rlp`.
///
/// `@ethereumjs/rlp` encodes a (possibly nested) structure in a single pass: byte
/// buffers become RLP byte-strings and arrays become RLP lists. We expose thin
/// wrappers returning Node Buffers, plus the hex/bigint → minimal-big-endian
/// normalizers the proof builders need (RLP does not trim leading zeros for the
/// integer fields its callers feed it).

/// RLP-encode a (possibly nested) structure of byte buffers and lists.
export function rlpEncode(input: Input): Buffer {
    return Buffer.from(RLP.encode(input));
}

/// Decode an already-encoded RLP byte string back into its nested structure — used to
/// splice an opaque pre-encoded list (e.g. a raw block header) into a larger RLP list.
export function rlpDecode(input: Uint8Array): Uint8Array | NestedUint8Array {
    return RLP.decode(input);
}

/// Hex (with/without `0x`) → Buffer, left-padding an odd nibble count. Empty for nullish/empty input.
export function hexToBuf(hex: string | undefined | null): Buffer {
    if (!hex) return Buffer.alloc(0);
    const h = hex.startsWith("0x") ? hex.slice(2) : hex;
    if (h.length === 0) return Buffer.alloc(0);
    return Buffer.from(h.length % 2 ? "0" + h : h, "hex");
}

/// Hex → minimal big-endian Buffer (leading zero nibbles stripped) — for RLP integer fields.
export function hexToTrimmedBuf(hex: string | undefined | null): Buffer {
    if (!hex || hex === "0x0" || hex === "0x") return Buffer.alloc(0);
    let h = hex.startsWith("0x") ? hex.slice(2) : hex;
    h = h.replace(/^0+/, "");
    if (h.length === 0) return Buffer.alloc(0);
    if (h.length % 2) h = "0" + h;
    return Buffer.from(h, "hex");
}

/// bigint → minimal big-endian Buffer (`0n` → empty) — for RLP integer fields.
export function bigintToTrimmedBuf(n: bigint): Buffer {
    if (n === 0n) return Buffer.alloc(0);
    return hexToTrimmedBuf("0x" + n.toString(16));
}

export function rlpEncodeLength(len: number, offset: number): Buffer {
    if (len < 56) return Buffer.from([offset + len]);
    const hexLen = len.toString(16);
    const lenBytes = Buffer.from(hexLen.length % 2 ? "0" + hexLen : hexLen, "hex");
    return Buffer.concat([Buffer.from([offset + 55 + lenBytes.length]), lenBytes]);
}

export function rlpBytes(buf: Buffer): Buffer {
    if (buf.length === 0) return Buffer.from([0x80]);
    if (buf.length === 1 && buf[0] < 0x80) return Buffer.from([buf[0]]);
    return Buffer.concat([rlpEncodeLength(buf.length, 0x80), buf]);
}

export function rlpList(items: Buffer[]): Buffer {
    const payload = Buffer.concat(items);
    return Buffer.concat([rlpEncodeLength(payload.length, 0xc0), payload]);
}
