/**
 * buildSeiProof.ts
 *
 * Builds the protobuf-encoded ClprSeiBundlePayload that SeiCometBftVerifier.verifyBundle expects.
 *
 * Sei CometBFT proof format (ClprSeiBundlePayload):
 *   field 1 (LEN): SeiStateProof {
 *       field 1 (LEN): SeiSignedHeader { header, commit }
 *       field 2 (LEN): store_key   — "evm" bytes
 *       field 3 (LEN): multistore_proof  — ICS-23 CommitmentProof (Tendermint spec)
 *       field 4 (LEN): [repeated] SeiStorageProofEntry { key, value, iavl_proof }
 *   }
 *   field 2 (LEN): ClprBundleContent { messages, next_trust_anchor }
 *   field 3 (LEN): SeiValidatorSet { validators } (optional, for validator rotation)
 *
 * The Sei REST API (LCD) endpoints used:
 *   GET /cosmos/base/tendermint/v1beta1/blocks/latest
 *     → signed header + commit
 *   GET /cosmos/base/tendermint/v1beta1/validatorsets/latest
 *     → validator set
 *   GET /cosmos/tx/v1beta1/txs?events=...
 *     → (not used here; ABCI query used for proofs instead)
 *   ABCI query /store/evm/key  with prove=true
 *     → ICS-23 IAVL proof for a storage slot
 *   ABCI query /store/ibc/key  (multistore proof via GetProofOps)
 *     → Tendermint ICS-23 proof for the "evm" store root
 *
 * Storage slot derivation (Sei x/evm module, keys.go):
 *   key = 0x03 || contractAddress(20) || slot(32)
 *
 * Channel struct offsets:
 *   index 0 → Channel slot+1 (status|nextMessageId)
 *   index 1 → Channel slot+2 (receivedMessageId packed)
 *   index 2 → Channel slot+4 (sentRunningHash)
 *   index 3 → Channel slot+5 (receivedRunningHash)
 */

import {encodeAbiParameters, type Hex, keccak256} from "viem";
import {pbLen, pbInt, pbBytes, pbVarint} from "../lib/proto.js";

// ─────────────────────────────────────────────────────────────────────────────
//  Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Channel struct mapping is at root slot 15 (from storage-layout.json).
const CHANNELS_SLOT = 15n;
const MESSAGE_QUEUES_SLOT = 1n;
const MESSAGE_RUNNING_HASH_OFFSET = 1n;
const EVM_STATE_KEY_PREFIX = 0x03;
const PROVEN_STRUCT_OFFSETS: bigint[] = [1n, 2n, 4n, 5n, 16n];

// ─────────────────────────────────────────────────────────────────────────────
//  Exported types
// ─────────────────────────────────────────────────────────────────────────────

export interface SeiValidator {
    /// 32-byte Ed25519 public key (hex).
    ed25519PubKey: Hex;
    /// Voting power (integer).
    votingPower: bigint;
}

export interface SeiProofPayload {
    /// Protobuf-encoded ClprSeiBundlePayload, ABI hex.
    proofBytes: Hex;
    /// ABI-encoded trust anchor: abi.encode(string chainId, bytes20 service, SeiValidator[]).
    trustAnchor: Hex;
}

export interface SeiStorageProofEntry {
    /// Raw storage key bytes (0x03 || address || slot32).
    key: Buffer;
    /// 32-byte storage value.
    value: Buffer;
    /// Serialised ICS-23 CommitmentProof (IAVL spec) bytes.
    iavlProof: Buffer;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Storage slot derivation
// ─────────────────────────────────────────────────────────────────────────────

function deriveMessageRunningHashSlot(channelId: Hex, messageId: bigint): Hex {
    const outer = BigInt(keccak256(encodeAbiParameters(
        [{type: "bytes32"}, {type: "uint256"}], [channelId, MESSAGE_QUEUES_SLOT]
    )));
    const inner = BigInt(keccak256(encodeAbiParameters(
        [{type: "uint256"}, {type: "uint256"}], [messageId, outer]
    )));
    const slot = (inner + MESSAGE_RUNNING_HASH_OFFSET) & ((1n << 256n) - 1n);
    return ("0x" + slot.toString(16).padStart(64, "0")) as Hex;
}

function deriveChannelSlots(channelId: Hex): Hex[] {
    const encoded = encodeAbiParameters(
        [{type: "bytes32"}, {type: "uint256"}], [channelId, CHANNELS_SLOT]
    );
    const base = BigInt(keccak256(encoded));
    return PROVEN_STRUCT_OFFSETS.map(off => {
        const s = (base + off) & ((1n << 256n) - 1n);
        return ("0x" + s.toString(16).padStart(64, "0")) as Hex;
    });
}

/// Build the Sei EVM state key: 0x03 || address(20) || slot(32).
export function seiStorageKey(serviceAddr: Hex, storageSlot: Hex): Buffer {
    const addrBuf = Buffer.from(serviceAddr.slice(2).padStart(40, "0"), "hex");
    const slotBuf = Buffer.from(storageSlot.slice(2).padStart(64, "0"), "hex");
    return Buffer.concat([Buffer.from([EVM_STATE_KEY_PREFIX]), addrBuf, slotBuf]);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Trust anchor encoding
// ─────────────────────────────────────────────────────────────────────────────

/// Encode the SeiCometBftVerifier trust anchor.
/// Format: abi.encode(string chainId, SeiValidator[])
/// where SeiValidator = (bytes32 ed25519PubKey, int64 votingPower).
/// The peer service address is NOT part of the anchor — it flows through
/// channelContext (ChannelContext.remoteServiceAddress) instead.
export function encodeTrustAnchor(
    chainId: string,
    validators: SeiValidator[]
): Hex {
    return encodeAbiParameters(
        [
            {type: "string"},
            {type: "tuple[]", components: [{type: "bytes32", name: "ed25519PubKey"}, {type: "int64", name: "votingPower"}]}
        ],
        [chainId, validators.map(v => ({ed25519PubKey: v.ed25519PubKey, votingPower: v.votingPower}))]
    ) as Hex;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Protobuf bundle content
// ─────────────────────────────────────────────────────────────────────────────

function bundleContentProto(payloads: Hex[], newTrustAnchor?: Buffer): Buffer {
    const parts: Buffer[] = [];
    for (const p of payloads) {
        const inner = Buffer.from(p.slice(2), "hex");
        parts.push(pbLen(2, inner));
    }
    if (newTrustAnchor && newTrustAnchor.length > 0) {
        parts.push(pbLen(3, newTrustAnchor));
    }
    return Buffer.concat(parts);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Main proof assembly
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Assemble a ClprSeiBundlePayload from pre-fetched components.
 *
 * This function does NOT perform any network calls — it expects the caller to have
 * already fetched all cryptographic material from a live Sei node (via LCD REST
 * or CometBFT RPC) and packaged it into the parameter types below.
 *
 * The e2e test (sei-verifier.spec.ts) is responsible for fetching these from the
 * Sei node and passing them here.
 *
 * @param signedHeaderProto  Serialised SeiSignedHeader proto bytes (from LCD).
 * @param storeKey           Raw "evm" bytes (3 bytes).
 * @param multistoreProof    ICS-23 CommitmentProof bytes (Tendermint spec).
 * @param storageProofEntries One entry per proven storage slot.
 * @param payloads           Message payloads to embed in ClprBundleContent.
 * @param nextValidatorSet   Optional serialised SeiValidatorSet for validator rotation.
 */
export function assembleSeiProof(opts: {
    signedHeaderProto: Buffer;
    storeKey: Buffer;
    multistoreProof: Buffer;
    storageProofEntries: SeiStorageProofEntry[];
    payloads: Hex[];
    nextValidatorSet?: Buffer;
    chainId: string;
    validators: SeiValidator[];
}): SeiProofPayload {
    const {
        signedHeaderProto, storeKey, multistoreProof,
        storageProofEntries, payloads, nextValidatorSet,
        chainId, validators,
    } = opts;

    // ── SeiStateProof ─────────────────────────────────────────────────────────
    const stateParts: Buffer[] = [
        pbLen(1, signedHeaderProto),
        pbLen(2, storeKey),
        pbLen(3, multistoreProof),
    ];
    for (const entry of storageProofEntries) {
        const entryBuf = Buffer.concat([
            pbLen(1, entry.key),
            pbLen(2, entry.value),
            pbLen(3, entry.iavlProof),
        ]);
        stateParts.push(pbLen(4, entryBuf));
    }
    const stateProof = Buffer.concat(stateParts);

    // ── ClprBundleContent ─────────────────────────────────────────────────────
    const bundleContent = bundleContentProto(payloads, nextValidatorSet);

    // ── ClprSeiBundlePayload ──────────────────────────────────────────────────
    const payload = Buffer.concat([
        pbLen(1, stateProof),
        pbLen(2, bundleContent),
        ...(nextValidatorSet ? [pbLen(3, nextValidatorSet)] : []),
    ]);

    const proofBytes = ("0x" + payload.toString("hex")) as Hex;
    const trustAnchor = encodeTrustAnchor(chainId, validators);

    return {proofBytes, trustAnchor};
}

// ─────────────────────────────────────────────────────────────────────────────
//  Config proof encoding
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Build the protobuf-encoded ClprSeiLedgerConfigurationPayload.
 *
 * Field layout:
 *   field 1 (LEN): SeiValidatorSet { validators (field 1 repeated) }
 *   field 2 (LEN): LedgerConfiguration { chainId, serviceAddress, throttles, ... }
 *   field 3 (LEN): SeiStateProof (same format as bundle, proves the service_address slot)
 */
export function buildSeiConfigProof(opts: {
    validators: SeiValidator[];
    chainId: string;
    serviceAddr: Hex;
    stateProof: Buffer;
}): Hex {
    const {validators, chainId, serviceAddr, stateProof} = opts;

    // Encode each validator: field 1 (LEN) = ed25519PubKey, field 2 (VARINT) = votingPower
    const validatorSetBuf = Buffer.concat(
        validators.map(v => {
            const pubKey = Buffer.from(v.ed25519PubKey.slice(2), "hex");
            const vpBuf  = v.votingPower !== 0n ? Buffer.concat([pbVarint(BigInt(2 << 3)), pbVarint(v.votingPower)]) : Buffer.alloc(0);
            return pbLen(1, Buffer.concat([pbLen(1, pubKey), vpBuf]));
        })
    );

    // LedgerConfiguration (minimal: chainId, serviceAddress, throttles)
    const throttles = Buffer.concat([
        pbInt(1, 100n), pbInt(2, 10n), pbInt(3, 100_000n),
        pbInt(4, 1_000_000n), pbInt(5, 1000n), pbInt(6, 100_000n), pbInt(7, 0n),
    ]);
    const ledgerConfig = Buffer.concat([
        pbBytes(2, Buffer.from(chainId, "utf8")),         // field 2 = chain_id (wait: check proto)
        pbBytes(3, Buffer.from(serviceAddr.slice(2), "hex")), // field 3 = service_address (wait: check proto)
        pbLen(4, throttles),                               // field 4 = throttles
    ]);

    // ClprSeiLedgerConfigurationPayload
    const payload = Buffer.concat([
        pbLen(1, validatorSetBuf),
        pbLen(2, ledgerConfig),
        pbLen(3, stateProof),
    ]);

    return ("0x" + payload.toString("hex")) as Hex;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Slot key helpers (exported for e2e test)
// ─────────────────────────────────────────────────────────────────────────────

export {deriveChannelSlots, deriveMessageRunningHashSlot};
