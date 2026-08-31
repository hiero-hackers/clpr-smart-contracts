/// Persists Besu RPC URLs between `npm run e2e:up:besu` and test runs.
/// Mirrors the pattern used by solo/state.ts for Solo relay URLs.
///
/// When `infra.ts up besu` completes it writes these files so that BesuNode
/// can detect a pre-started compose stack and skip launching its own containers.

import {mkdir, readFile, unlink, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

/// Fixed host ports used when the compose stack is started externally.
/// These match the port mapping in docker-compose.yml ("18545:8545", "18546:8545").
export const BESU_EXTERNAL_RPC_A = "http://127.0.0.1:18545";
export const BESU_EXTERNAL_RPC_B = "http://127.0.0.1:18546";

const STATE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../backend/.besu-state");

function rpcFile(side: "a" | "b"): string {
    return path.join(STATE_DIR, `rpc-${side}.url`);
}

export async function writeBesuRpcUrl(side: "a" | "b", rpc: string): Promise<void> {
    await mkdir(STATE_DIR, {recursive: true});
    await writeFile(rpcFile(side), `${rpc}\n`, "utf8");
}

export async function readBesuRpcUrl(side: "a" | "b"): Promise<string | undefined> {
    try {
        const url = (await readFile(rpcFile(side), "utf8")).trim();
        return url || undefined;
    } catch {
        return undefined;
    }
}

export async function clearBesuRpcUrl(side: "a" | "b"): Promise<void> {
    try { await unlink(rpcFile(side)); } catch { /* already gone */ }
}

export async function clearBesuState(): Promise<void> {
    await Promise.all([clearBesuRpcUrl("a"), clearBesuRpcUrl("b")]);
}
