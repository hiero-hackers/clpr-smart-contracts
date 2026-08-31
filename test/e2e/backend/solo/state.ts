import {mkdir, readFile, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {mirrorRestUrlFor, relayRpcUrlFor, type SoloSide} from "./config.ts";

const STATE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "../.solo-state");

export function relayUrlFile(side: SoloSide): string {
    return path.join(STATE_DIR, `relay-${side}.url`);
}

export function mirrorUrlFile(side: SoloSide): string {
    return path.join(STATE_DIR, `mirror-${side}.url`);
}

export function blockNodeUrlFile(side: SoloSide): string {
    return path.join(STATE_DIR, `block-node-${side}.url`);
}

export async function writeRelayUrl(side: SoloSide, rpc: string): Promise<void> {
    await mkdir(STATE_DIR, {recursive: true});
    await writeFile(relayUrlFile(side), `${rpc}\n`, "utf8");
}

export async function writeMirrorUrl(side: SoloSide, url: string): Promise<void> {
    await mkdir(STATE_DIR, {recursive: true});
    await writeFile(mirrorUrlFile(side), `${url}\n`, "utf8");
}

export async function writeBlockNodeUrl(side: SoloSide, hostPort: string): Promise<void> {
    await mkdir(STATE_DIR, {recursive: true});
    await writeFile(blockNodeUrlFile(side), `${hostPort}\n`, "utf8");
}

export async function readRelayUrl(side: SoloSide): Promise<string | undefined> {
    try {
        const url = (await readFile(relayUrlFile(side), "utf8")).trim();
        return url || undefined;
    } catch {
        return undefined;
    }
}

export async function readMirrorUrl(side: SoloSide): Promise<string | undefined> {
    try {
        const url = (await readFile(mirrorUrlFile(side), "utf8")).trim();
        return url || undefined;
    } catch {
        return undefined;
    }
}

export async function readBlockNodeUrl(side: SoloSide): Promise<string | undefined> {
    try {
        const url = (await readFile(blockNodeUrlFile(side), "utf8")).trim();
        return url || undefined;
    } catch {
        return undefined;
    }
}

export async function resolveRelayUrl(side: SoloSide): Promise<string | undefined> {
    const cached = await readRelayUrl(side);
    if (cached) return cached;
    return relayRpcUrlFor(side);
}

export async function resolveMirrorUrl(side: SoloSide): Promise<string | undefined> {
    const cached = await readMirrorUrl(side);
    if (cached) return cached;
    return mirrorRestUrlFor(side);
}

export async function resolveBlockNodeUrl(side: SoloSide): Promise<string | undefined> {
    return readBlockNodeUrl(side);
}

export async function applySoloRpcEnv(): Promise<void> {
    for (const side of ["a", "b"] as const) {
        const relay = await resolveRelayUrl(side);
        if (relay) process.env[side === "a" ? "SOLO_RPC_A" : "SOLO_RPC_B"] = relay;

        const mirror = await resolveMirrorUrl(side);
        if (mirror) {
            process.env[side === "a" ? "CLPR_SOLO_MIRROR_URL_A" : "CLPR_SOLO_MIRROR_URL_B"] = mirror;
            // Side B is the usual Solo peer in besu:solo — keep a single env alias.
            if (side === "b") process.env.CLPR_SOLO_MIRROR_URL = mirror;
        }

        const blockNode = await resolveBlockNodeUrl(side);
        if (blockNode) {
            process.env[side === "a" ? "CLPR_SOLO_BLOCK_NODE_A" : "CLPR_SOLO_BLOCK_NODE_B"] = blockNode;
            if (side === "b") process.env.CLPR_SOLO_BLOCK_NODE = blockNode;
        }
    }
}
