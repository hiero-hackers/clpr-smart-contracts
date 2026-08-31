import {spawn, type ChildProcess} from "node:child_process";
import {createPublicClient, http} from "viem";
import type {ChainNode} from "../ChainNode.js";

/// A single Anvil process. Port and chainId are supplied at construction so the
/// same class works for both the A-slot (port 8545 / chainId 1337) and the
/// B-slot (port 8546 / chainId 1338).
export class AnvilNode implements ChainNode {
    private proc?: ChildProcess;

    private static readonly FUNDED_KEY: `0x${string}` =
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    constructor(
        private readonly port: number,
        private readonly chainId: number
    ) {}

    kind() { return "anvil" as const; }
    rpc() { return `http://127.0.0.1:${this.port}`; }
    caip() { return `eip155:${this.chainId}`; }
    fundedKey() { return AnvilNode.FUNDED_KEY; }
    supportsSnapshots() { return true; }

    async start(): Promise<void> {
        this.proc = spawn(
            "anvil",
            ["--port", String(this.port), "--chain-id", String(this.chainId), "--silent"],
            {stdio: process.env.CLPR_LOG === "trace" ? "inherit" : ["ignore", "ignore", "pipe"]}
        );
        this.proc.stderr?.on("data", (chunk: Buffer) => {
            console.error(`[anvil:${this.port}] ${chunk.toString().trimEnd()}`);
        });
        this.proc.on("error", (err) => {
            console.error(`[anvil:${this.port}] spawn failed:`, err.message);
        });
        this.proc.on("exit", (code, signal) => {
            if (code !== 0 && code !== null) {
                console.error(`[anvil:${this.port}] exited unexpectedly: code=${code} signal=${signal}`);
            }
        });
        await this.waitReady();
    }

    async stop(): Promise<void> {
        if (process.env.CLPR_KEEP_NODES === "1") {
            console.log(`[anvil] CLPR_KEEP_NODES=1 — leaving anvil running. PID: ${this.proc?.pid}`);
            return;
        }
        this.proc?.kill("SIGTERM");
        await new Promise((r) => setTimeout(r, 100));
    }

    private async waitReady(): Promise<void> {
        const client = createPublicClient({transport: http(this.rpc())});
        const deadline = Date.now() + 15_000;
        let lastErr: unknown;
        while (Date.now() < deadline) {
            try {
                await client.getChainId();
                return;
            } catch (err) {
                lastErr = err;
                await new Promise((r) => setTimeout(r, 100));
            }
        }
        throw new Error(`anvil at ${this.rpc()} not ready within 15s. Is foundry installed? Last error: ${String(lastErr)}`);
    }
}
