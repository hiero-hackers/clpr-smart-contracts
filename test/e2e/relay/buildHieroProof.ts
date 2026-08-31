import type {Hex} from "viem";
import type {ChainClients} from "../lib/clients.js";
import {
    getLatestBlock,
    getStateProof,
    mergeStateProofPaths
} from "../lib/blockNodeClient.js";
import {resolveSoloBlockNodeGrpc} from "../lib/soloBlockNode.js";
import {resolveSoloMirrorBaseUrl} from "../lib/soloMirror.js";
import {encodeSlotKey} from "../lib/slotKey.js";
import {
    deriveChannelFieldSlots,
    deriveMessagePayloadSlot,
    deriveMessageRunningHashSlot
} from "../lib/storageSlots.js";

export interface HieroProofPayload {
    proofBytes: Hex;
    trustAnchor: Hex;
}

const PROOF_STATUS_SUCCESS = 1;

/// Build a TSS-signed `StateProof` from EVM-deployed `ClprService` storage on Solo.
///
/// Requires `ProofService.getStateProof` per SlotKey (HIP-1081) on the block node.
export async function buildHieroProof(opts: {
    source: ChainClients;
    serviceAddr: Hex;
    channelId: Hex;
    range: {fromId: bigint; throughId: bigint};
    trustAnchor: Hex;
    mirrorBaseUrl?: string;
    blockNodeGrpc?: string;
}): Promise<HieroProofPayload> {
    const {source, serviceAddr, channelId, range, trustAnchor} = opts;
    const mirrorBaseUrl = opts.mirrorBaseUrl ?? await resolveSoloMirrorBaseUrl("b");
    const blockNodeGrpc = opts.blockNodeGrpc ?? await resolveSoloBlockNodeGrpc("b");

    if (!mirrorBaseUrl) {
        throw new Error("buildHieroProof: set CLPR_SOLO_MIRROR_URL or run e2e:solo:up");
    }
    if (!blockNodeGrpc) {
        throw new Error("buildHieroProof: set CLPR_SOLO_BLOCK_NODE or run e2e:solo:up with block node");
    }

    const channelSlots = deriveChannelFieldSlots(channelId);

    const messageSlots: {id: bigint; payloadSlot: Hex; hashSlot: Hex}[] = [];
    for (let id = range.fromId; id <= range.throughId; id++) {
        messageSlots.push({
            id,
            payloadSlot: deriveMessagePayloadSlot(channelId, id),
            hashSlot: deriveMessageRunningHashSlot(channelId, id)
        });
    }

    const contractId = await resolveContractId(mirrorBaseUrl, serviceAddr);
    const latest = await getLatestBlock(blockNodeGrpc);
    const blockNumber = latest.blockNumber;

    const slotKeys = [
        ...channelSlots.map((slot) => ({slot, key: encodeSlotKey(contractId, slot)})),
        ...messageSlots.flatMap((m) => [
            {slot: m.payloadSlot, key: encodeSlotKey(contractId, m.payloadSlot)},
            {slot: m.hashSlot, key: encodeSlotKey(contractId, m.hashSlot)}
        ])
    ];

    const collectedProofs: Buffer[] = [];

    for (const {key} of slotKeys) {
        const resp = await getStateProof(blockNodeGrpc, blockNumber, key);
        if (resp.status !== PROOF_STATUS_SUCCESS || !resp.stateProof?.length) {
            throw new Error(
                `getStateProof(block=${blockNumber}, key=${key.subarray(0, 8).toString("hex")}…) ` +
                `status=${resp.status}`
            );
        }
        collectedProofs.push(resp.stateProof);
    }

    const proofBytes = mergeStateProofPaths(collectedProofs, latest.signedBlockProof);
    return {proofBytes: `0x${proofBytes.toString("hex")}` as Hex, trustAnchor};
}

async function resolveContractId(mirrorBaseUrl: string, evmAddress: Hex): Promise<string> {
    const url = `${mirrorBaseUrl.replace(/\/$/, "")}/api/v1/contracts/${evmAddress}`;
    const res = await fetch(url);
    if (!res.ok) {
        throw new Error(`mirror GET ${url} failed: ${res.status} ${await res.text()}`);
    }
    const json = (await res.json()) as {contract_id?: string};
    if (!json.contract_id) throw new Error(`mirror contract lookup missing contract_id for ${evmAddress}`);
    return json.contract_id;
}
