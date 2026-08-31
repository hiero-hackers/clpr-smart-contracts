import {pbBool, pbFindField, pbFindVarint, pbInt, pbBytes, pbScanLen, type PbField} from "../lib/proto.js";
import {grpcOk, grpcUnary, type GrpcUnaryResult} from "./grpc.js";

const BLOCK_ACCESS_GET_BLOCK = "/org.hiero.block.api.BlockAccessService/getBlock";
const PROOF_GET_STATE_PROOF = "/org.hiero.block.api.ProofService/getStateProof";

/** gRPC status UNIMPLEMENTED — ProofService is absent on block node v0.33.x. */
const GRPC_UNIMPLEMENTED = 12;

export const PROOF_SERVICE_NOT_IMPLEMENTED_MSG =
    "ProofService.getStateProof is not implemented on block node v0.33.x";

export class ProofServiceNotImplementedError extends Error {
    constructor(message = PROOF_SERVICE_NOT_IMPLEMENTED_MSG) {
        super(message);
        this.name = "ProofServiceNotImplementedError";
    }
}

export function isProofServiceNotImplementedError(err: unknown): boolean {
    return err instanceof ProofServiceNotImplementedError;
}

export interface BlockNodeBlock {
    blockNumber: bigint;
    signedBlockProof: Buffer;
    blockProof: Buffer;
    items: Buffer[];
}

export interface StateProofResult {
    status: number;
    stateProof?: Buffer;
}

function decodeBlockResponse(body: Buffer): BlockNodeBlock {
    const status = pbFindVarint(body, 1);
    if (status !== 1n) {
        throw new Error(`BlockAccessService.getBlock status=${status ?? "?"}`);
    }
    const block = pbFindField(body, 2);
    if (!block) throw new Error("BlockAccessService.getBlock missing block");

    let blockNumber = 0n;
    const items: Buffer[] = [];
    let blockProof: Buffer | undefined;

    for (const itemWire of pbScanLen(block).filter((f: PbField) => f.field === 1)) {
        items.push(itemWire.data);
        for (const sub of pbScanLen(itemWire.data)) {
            if (sub.field === 1) {
                const header = sub.data;
                const num = pbFindVarint(header, 3);
                if (num !== undefined) blockNumber = num;
            } else if (sub.field === 9) {
                blockProof = sub.data;
            }
        }
    }

    if (!blockProof) throw new Error("block stream missing block_proof item");
    const signedBlockProof = pbFindField(blockProof, 2);
    if (!signedBlockProof) throw new Error("block_proof missing signed_block_proof");

    return {blockNumber, signedBlockProof, blockProof, items};
}

function assertProofServiceAvailable(result: GrpcUnaryResult): void {
    if (result.status < 0 || result.status === GRPC_UNIMPLEMENTED) {
        throw new ProofServiceNotImplementedError(
            `${PROOF_SERVICE_NOT_IMPLEMENTED_MSG} (grpc-status=${result.status})`
        );
    }
}

export async function getLatestBlock(hostPort: string): Promise<BlockNodeBlock> {
    const request = pbBool(2, true); // retrieve_latest = true
    const result = await grpcUnary(hostPort, BLOCK_ACCESS_GET_BLOCK, request);
    if (!grpcOk(result)) {
        throw new Error(
            `getBlock failed: grpc-status=${result.status} ${decodeURIComponent(result.message)}`
        );
    }
    return decodeBlockResponse(result.body);
}

export async function getBlockAt(hostPort: string, blockNumber: bigint): Promise<BlockNodeBlock> {
    const request = pbInt(1, blockNumber);
    const result = await grpcUnary(hostPort, BLOCK_ACCESS_GET_BLOCK, request);
    if (!grpcOk(result)) {
        throw new Error(
            `getBlock(${blockNumber}) failed: grpc-status=${result.status} ${decodeURIComponent(result.message)}`
        );
    }
    return decodeBlockResponse(result.body);
}

/// Request a SlotKey state proof via `ProofService.getStateProof` (HIP-1081).
export async function getStateProof(
    hostPort: string,
    blockNumber: bigint,
    stateKey: Buffer
): Promise<StateProofResult> {
    const request = Buffer.concat([pbInt(1, blockNumber), pbBytes(2, stateKey)]);
    let result: GrpcUnaryResult;
    try {
        result = await grpcUnary(hostPort, PROOF_GET_STATE_PROOF, request);
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        throw new Error(`getStateProof RPC failed (${hostPort}): ${msg}`);
    }

    assertProofServiceAvailable(result);

    if (!grpcOk(result)) {
        throw new Error(
            `getStateProof failed: grpc-status=${result.status} ${decodeURIComponent(result.message)}`
        );
    }
    return {
        status: Number(pbFindVarint(result.body, 1) ?? 1n),
        stateProof: pbFindField(result.body, 2)
    };
}

/// Merge path entries from multiple `StateProof` blobs; keep one `signed_block_proof`.
export function mergeStateProofPaths(proofs: Buffer[], signedBlockProof: Buffer): Buffer {
    const pathSet = new Map<string, Buffer>();
    for (const proof of proofs) {
        for (const f of pbScanLen(proof)) {
            if (f.field === 1) pathSet.set(f.data.toString("hex"), f.data);
        }
    }
    const parts: Buffer[] = [];
    for (const path of pathSet.values()) parts.push(pbBytes(1, path));
    parts.push(pbBytes(2, signedBlockProof));
    return Buffer.concat(parts);
}

export async function isProofServiceAvailable(hostPort: string): Promise<boolean> {
    try {
        await getStateProof(hostPort, 0n, Buffer.alloc(0));
        return true;
    } catch (err) {
        if (isProofServiceNotImplementedError(err)) return false;
        throw err;
    }
}
