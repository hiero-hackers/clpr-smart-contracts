import {blockNodeGrpcUrlFor, loadSoloGlobalConfig, type SoloSide} from "../backend/solo/config.ts";
import {readBlockNodeUrl} from "../backend/solo/state.ts";

/// Resolve block node gRPC `host:port` for HIP-1081 APIs (`BlockAccessService`, future `ProofService`).
export async function resolveSoloBlockNodeGrpc(side: SoloSide = "b"): Promise<string | undefined> {
    const explicit =
        process.env.CLPR_SOLO_BLOCK_NODE ??
        process.env[side === "a" ? "CLPR_SOLO_BLOCK_NODE_A" : "CLPR_SOLO_BLOCK_NODE_B"];
    if (explicit) return explicit.replace(/^https?:\/\//, "");

    const cached = await readBlockNodeUrl(side);
    if (cached) return cached;

    if (!loadSoloGlobalConfig().enableBlockNode) return undefined;
    return blockNodeGrpcUrlFor(side);
}
