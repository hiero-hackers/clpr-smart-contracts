import {readFileSync} from "node:fs";
import type {Hex} from "viem";
import {STATE_PROOF_BIN, STATE_PROOF_JSON, stateProofJsonExists} from "./config.js";

const HINTS_VK_LEN = 1096;
const HINTS_KEY_LEN = 128; // first 128 bytes of the VK (n + total_weight, used as pinned-key fingerprint)

/**
 * Extract the hintsKey (first 128 bytes of the hintsVK) from stateProof.bin.
 * StateProof field 2 = SignedBlockProof; its field 1 = block_signature bytes.
 * The block_signature starts with the HINTS_VK_LEN-byte VK.
 */
export function hintsKeyHex(): Hex {
    function readVarint(buf: Buffer, i: number): [bigint, number] {
        let v = 0n, shift = 0n;
        for (;;) { const b = BigInt(buf[i++]); v |= (b & 0x7fn) << shift; if (!(b & 0x80n)) break; shift += 7n; }
        return [v, i];
    }
    const data = readFileSync(STATE_PROOF_BIN);
    let pos = 0;
    while (pos < data.length) {
        const [key, ni] = readVarint(data, pos); pos = ni;
        const fn = Number(key >> 3n), wt = Number(key & 7n);
        if (wt !== 2) { pos++; continue; }
        const [len, ds] = readVarint(data, pos); pos = ds + Number(len);
        if (fn !== 2) continue; // field 2 = SignedBlockProof
        const sbp = data.subarray(ds, ds + Number(len));
        let j = 0;
        while (j < sbp.length) {
            const [k, nj] = readVarint(sbp, j); j = nj;
            const sf = Number(k >> 3n), sw = Number(k & 7n);
            if (sw !== 2) { j++; continue; }
            const [sl, sd] = readVarint(sbp, j); j = sd + Number(sl);
            if (sf !== 1) continue; // field 1 = block_signature
            const sig = sbp.subarray(sd, sd + Number(sl));
            if (sig.length < HINTS_KEY_LEN) throw new Error(`signature too short: ${sig.length}`);
            return `0x${sig.subarray(0, HINTS_KEY_LEN).toString("hex")}` as Hex;
        }
    }
    throw new Error("block_signature not found in stateProof.bin");
}

function readVarint(buf: Buffer, i: number): [bigint, number] {
    let v = 0n;
    let shift = 0n;
    for (;;) {
        const b = BigInt(buf[i++]);
        v |= (b & 0x7fn) << shift;
        if ((b & 0x80n) === 0n) break;
        shift += 7n;
    }
    return [v, i];
}

/** Best-effort decode of the channel StateItem leaf (for logging). */
export function decodeChannelLeafFromProof(): {
    hederaChannelId: string;
    chainId: string;
    status?: number;
    nextMessageId?: number;
    sentRunningHash?: string;
    receivedRunningHash?: string;
} | null {
    if (!stateProofJsonExists()) return null;
    const raw = JSON.parse(readFileSync(STATE_PROOF_JSON, "utf8")) as {
        paths: {stateItemLeaf?: string}[];
    };
    const b64 = raw.paths[0]?.stateItemLeaf;
    if (!b64) return null;

    const leaf = Buffer.from(b64, "base64");
    let i = 0;
    while (i < leaf.length) {
        const [key, ni] = readVarint(leaf, i);
        i = ni;
        const fn = Number(key >> 3n);
        const wt = Number(key & 7n);
        if (wt !== 2 || fn !== 3) {
            if (wt === 2) {
                const [len, ds] = readVarint(leaf, i);
                i = ds + Number(len);
            } else if (wt === 0) {
                const [, n] = readVarint(leaf, i);
                i = n;
            } else break;
            continue;
        }
        const [len, ds] = readVarint(leaf, i);
        i = ds + Number(len);
        const outer = leaf.subarray(ds, ds + Number(len));
        let j = 0;
        const [outerKey, jAfterKey] = readVarint(outer, j);
        j = jAfterKey;
        if (Number(outerKey >> 3n) !== 60) return null;
        const [innerLen, innerStart] = readVarint(outer, j);
        const inner = outer.subarray(innerStart, innerStart + Number(innerLen));
        const conn: Record<string, string | number | undefined> = {};
        let k = 0;
        while (k < inner.length) {
            const [k2, nk] = readVarint(inner, k);
            k = nk;
            const f = Number(k2 >> 3n);
            const w = Number(k2 & 7n);
            if (w === 0) {
                const [v, n] = readVarint(inner, k);
                k = n;
                if (f === 7) conn.status = Number(v);
                else if (f === 8) conn.nextMessageId = Number(v);
            } else if (w === 2) {
                const [l, ds2] = readVarint(inner, k);
                k = ds2 + Number(l);
                const slice = inner.subarray(ds2, ds2 + Number(l));
                if (f === 1) conn.hederaChannelId = `0x${slice.toString("hex")}`;
                else if (f === 2) conn.chainId = slice.toString("utf8");
                else if (f === 10) conn.sentRunningHash = `0x${slice.toString("hex")}`;
                else if (f === 12) conn.receivedRunningHash = `0x${slice.toString("hex")}`;
            }
        }
        return conn as {
            hederaChannelId: string;
            chainId: string;
            status?: number;
            nextMessageId?: number;
            sentRunningHash?: string;
            receivedRunningHash?: string;
        };
    }
    return null;
}
