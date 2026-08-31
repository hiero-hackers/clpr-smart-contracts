/// Persists Avalanche RPC URLs between `npm run e2e:up:avalanche` and test runs.
/// Mirrors the pattern used by besu/state.ts and solo/state.ts.
///
/// When `infra.ts up avalanche` completes it writes these files so that AvalancheNode
/// can detect a pre-started compose stack and skip launching its own containers.

import {mkdir, readFile, unlink, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

/// Fixed host ports used when the compose stack is started externally.
/// These match the port mapping in docker-compose.yml ("19650:9650", "19651:9650").
export const AVALANCHE_EXTERNAL_RPC_A = "http://127.0.0.1:19650/ext/bc/C/rpc";
export const AVALANCHE_EXTERNAL_RPC_B = "http://127.0.0.1:19651/ext/bc/C/rpc";

const STATE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../backend/.avalanche-state");

function rpcFile(side: "a" | "b"): string {
    return path.join(STATE_DIR, `rpc-${side}.url`);
}

export async function writeAvalancheRpcUrl(side: "a" | "b", rpc: string): Promise<void> {
    await mkdir(STATE_DIR, {recursive: true});
    await writeFile(rpcFile(side), `${rpc}\n`, "utf8");
}

export async function readAvalancheRpcUrl(side: "a" | "b"): Promise<string | undefined> {
    try {
        const url = (await readFile(rpcFile(side), "utf8")).trim();
        return url || undefined;
    } catch {
        return undefined;
    }
}

export async function clearAvalancheRpcUrl(side: "a" | "b"): Promise<void> {
    try { await unlink(rpcFile(side)); } catch { /* already gone */ }
}

export async function clearAvalancheState(): Promise<void> {
    await Promise.all([clearAvalancheRpcUrl("a"), clearAvalancheRpcUrl("b")]);
}
