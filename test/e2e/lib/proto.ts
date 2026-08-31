import type {Hex} from "viem";

/// Minimal hand-written proto3 encoder/decoder for e2e proof and config messages.
/// Wire types: 0 = varint, 2 = LEN.

export function pbVarint(n: bigint): Buffer {
    const b: number[] = [];
    while (n >= 0x80n) { b.push(Number(n & 0x7fn) | 0x80); n >>= 7n; }
    b.push(Number(n));
    return Buffer.from(b);
}

export function pbLen(fieldNum: number, data: Buffer): Buffer {
    return Buffer.concat([pbVarint(BigInt((fieldNum << 3) | 2)), pbVarint(BigInt(data.length)), data]);
}

export function pbInt(fieldNum: number, value: bigint): Buffer {
    return Buffer.concat([pbVarint(BigInt(fieldNum << 3)), pbVarint(value)]);
}

export function pbStr(fieldNum: number, s: string): Buffer {
    return pbLen(fieldNum, Buffer.from(s, "utf8"));
}

export function pbBytes(fieldNum: number, data: Buffer | Hex): Buffer {
    const buf = typeof data === "string" ? Buffer.from(data.replace("0x", ""), "hex") : data;
    return pbLen(fieldNum, buf);
}

export function pbBool(fieldNum: number, value: boolean): Buffer {
    return pbInt(fieldNum, value ? 1n : 0n);
}

export type PbField = {field: number; wire: number; data: Buffer};

/// Scan length-delimited top-level protobuf fields.
export function pbScanLen(buf: Buffer): PbField[] {
    const out: PbField[] = [];
    let pos = 0;
    while (pos < buf.length) {
        const [key, next] = pbReadVarint(buf, pos);
        pos = next;
        const field = Number(key >> 3n);
        const wire = Number(key & 7n);
        if (wire === 2) {
            const [len, dataStart] = pbReadVarint(buf, pos);
            const end = dataStart + Number(len);
            out.push({field, wire, data: buf.subarray(dataStart, end)});
            pos = end;
        } else if (wire === 0) {
            const [, skip] = pbReadVarint(buf, pos);
            out.push({field, wire, data: Buffer.alloc(0)});
            pos = skip;
        } else if (wire === 5) {
            pos += 4;
        } else if (wire === 1) {
            pos += 8;
        } else {
            break;
        }
    }
    return out;
}

export function pbReadVarint(buf: Buffer, start: number): [bigint, number] {
    let v = 0n;
    let shift = 0n;
    let i = start;
    for (;;) {
        const b = BigInt(buf[i++]);
        v |= (b & 0x7fn) << shift;
        if ((b & 0x80n) === 0n) break;
        shift += 7n;
    }
    return [v, i];
}

export function pbFindField(buf: Buffer, fieldNum: number): Buffer | undefined {
    return pbScanLen(buf).find((f) => f.field === fieldNum && f.wire === 2)?.data;
}

export function pbFindVarint(buf: Buffer, fieldNum: number): bigint | undefined {
    let pos = 0;
    while (pos < buf.length) {
        const [key, next] = pbReadVarint(buf, pos);
        pos = next;
        const field = Number(key >> 3n);
        const wire = Number(key & 7n);
        if (field === fieldNum && wire === 0) {
            const [v] = pbReadVarint(buf, pos);
            return v;
        }
        if (wire === 2) {
            const [len, dataStart] = pbReadVarint(buf, pos);
            pos = dataStart + Number(len);
        } else if (wire === 0) {
            const [, skip] = pbReadVarint(buf, pos);
            pos = skip;
        } else break;
    }
    return undefined;
}
