import {createHash} from "node:crypto";

/// SSZ signing-root construction mirroring `ClprBeaconSsz` — used to produce the exact 32-byte message
/// the sync committee signs, so a relay-generated BLS signature verifies on-chain.

function sha256(...parts: Buffer[]): Buffer {
    const h = createHash("sha256");
    for (const p of parts) h.update(p);
    return h.digest();
}

/// SSZ uint64 → little-endian, zero-padded to 32 bytes (`_uint64ToLE32`).
function uint64ToLE32(v: bigint): Buffer {
    const b = Buffer.alloc(32);
    b.writeBigUInt64LE(v & ((1n << 64n) - 1n), 0);
    return b;
}

/// Merkleize exactly 8 chunks (`_merkleize8`).
function merkleize8(chunks: Buffer[]): Buffer {
    const n00 = sha256(chunks[0], chunks[1]);
    const n01 = sha256(chunks[2], chunks[3]);
    const n10 = sha256(chunks[4], chunks[5]);
    const n11 = sha256(chunks[6], chunks[7]);
    return sha256(sha256(n00, n01), sha256(n10, n11));
}

/// `hash_tree_root(BeaconBlockHeader)` over [slot, proposerIndex, parentRoot, stateRoot, bodyRoot]
/// padded to 8 chunks (`beaconBlockHeaderRoot`).
export function beaconBlockHeaderRoot(
    slot: bigint,
    proposerIndex: bigint,
    parentRoot: Buffer,
    stateRoot: Buffer,
    bodyRoot: Buffer
): Buffer {
    const zero = Buffer.alloc(32);
    return merkleize8([
        uint64ToLE32(slot),
        uint64ToLE32(proposerIndex),
        parentRoot,
        stateRoot,
        bodyRoot,
        zero,
        zero,
        zero
    ]);
}

/// `compute_domain(DOMAIN_SYNC_COMMITTEE, forkVersion, gvr)` (`computeSyncCommitteeDomain`).
/// domain = 0x07000000 || sha256(pad32(forkVersion) || gvr)[0:28].
export function computeSyncCommitteeDomain(forkVersion: Buffer, gvr: Buffer): Buffer {
    if (forkVersion.length !== 4) throw new Error("forkVersion must be 4 bytes");
    if (gvr.length !== 32) throw new Error("gvr must be 32 bytes");
    const paddedVersion = Buffer.concat([forkVersion, Buffer.alloc(28)]);
    const forkDataRoot = sha256(paddedVersion, gvr);
    const domain = Buffer.alloc(32);
    domain[0] = 0x07; // DOMAIN_SYNC_COMMITTEE prefix; bytes 1..3 stay zero
    forkDataRoot.copy(domain, 4, 0, 28); // forkDataRoot[0:28] into the low 28 bytes
    return domain;
}

/// signing_root = sha256(blockHeaderRoot || domain) (`computeSigningRoot`).
export function computeSigningRoot(blockHeaderRoot: Buffer, domain: Buffer): Buffer {
    return sha256(blockHeaderRoot, domain);
}

/// SSZ leaf for a 48-byte compressed BLS pubkey: sha256(pubkey48 || 16 zero bytes) (`_pubkeyHash64`).
function pubkeyLeaf(compressed48: Buffer): Buffer {
    if (compressed48.length !== 48) throw new Error("compressed pubkey must be 48 bytes");
    return sha256(compressed48, Buffer.alloc(16));
}

/// SSZ balanced-binary merkleization over a power-of-two number of 32-byte leaves (`merkleize`).
function merkleize(leaves: Buffer[]): Buffer {
    if (leaves.length === 0 || (leaves.length & (leaves.length - 1)) !== 0) {
        throw new Error("merkleize: leaf count must be a power of two");
    }
    let nodes = leaves;
    while (nodes.length > 1) {
        const next: Buffer[] = [];
        for (let i = 0; i < nodes.length; i += 2) next.push(sha256(nodes[i], nodes[i + 1]));
        nodes = next;
    }
    return nodes[0];
}

/// `hash_tree_root(SyncCommittee)` from the compressed (48-byte) pubkeys — the beacon-native encoding
/// the `next_sync_committee` proof commits to. The contract reconstructs this same root from the
/// uncompressed keys (`ClprBeaconSsz.syncCommitteeRootFromUncompressed`), compressing each on the fly.
export function syncCommitteeRootFromCompressed(compressedPubkeys: Buffer[], compressedAggregate: Buffer): Buffer {
    const pubkeysRoot = merkleize(compressedPubkeys.map(pubkeyLeaf));
    return sha256(pubkeysRoot, pubkeyLeaf(compressedAggregate));
}
