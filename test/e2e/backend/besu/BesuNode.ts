import path from "node:path";
import {fileURLToPath} from "node:url";
import {DockerComposeEnvironment, Wait, type StartedDockerComposeEnvironment} from "testcontainers";
import {createPublicClient, http} from "viem";
import type {ChainNode} from "../ChainNode.js";
import {readBesuRpcUrl} from "./state.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/// A single Besu node driven via docker-compose.
///
/// Two startup modes:
///   External (pre-started): if `npm run e2e:up:besu` was run beforehand a
///     state file records the RPC URL. BesuNode reads it and skips
///     Testcontainers entirely — stop() is a no-op.
///   Inline (Testcontainers): if no state file is present, BesuNode spins
///     up only the required service and tears it down after the run.
export class BesuNode implements ChainNode {
    private env?: StartedDockerComposeEnvironment;
    private _external = false;
    private _rpc = "";

    private static readonly FUNDED_KEY: `0x${string}` =
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    /// `slot`: "a" → besu-a service, port 18545, chainId 1337
    ///         "b" → besu-b service, port 18546, chainId 1338
    constructor(private readonly slot: "a" | "b") {}

    private get service() { return `besu-${this.slot}` as const; }
    private get chainId() { return this.slot === "a" ? 1337 : 1338; }

    kind() { return "besu" as const; }
    rpc() {
        if (!this._rpc) throw new Error(`BesuNode(${this.slot}) not started`);
        return this._rpc;
    }
    caip() { return `eip155:${this.chainId}`; }
    fundedKey() { return BesuNode.FUNDED_KEY; }
    supportsSnapshots() { return false; }

    async start(): Promise<void> {
        // ── External mode: reuse a pre-started compose stack ──────────────────
        const ext = await readBesuRpcUrl(this.slot);
        if (ext) {
            this._rpc = ext;
            this._external = true;
            console.log(`[besu] reusing pre-started nodes ${this.slot === "a" ? "A" : "B"}=${ext}`);
            await this.waitReady();
            return;
        }

        // ── Inline mode: spin up via Testcontainers ───────────────────────────
        let compose = new DockerComposeEnvironment(path.join(__dirname, ".."), "docker-compose.yml")
            .withStartupTimeout(90_000)
            .withWaitStrategy(`${this.service}-1`, Wait.forListeningPorts());

        this.env = await compose.up([this.service]);
        const container = this.env.getContainer(`${this.service}-1`);
        this._rpc = `http://${container.getHost()}:${container.getMappedPort(8545)}`;
        await this.waitReady();
    }

    async stop(): Promise<void> {
        if (this._external) {
            console.log("[besu] pre-started nodes — leaving compose stack up. Tear down with: npm run e2e:down:besu");
            return;
        }
        if (process.env.CLPR_KEEP_NODES === "1") {
            console.log("[besu] CLPR_KEEP_NODES=1 — leaving compose stack up. Tear down with: npm run e2e:down:besu");
            return;
        }
        await this.env?.down({removeVolumes: true});
    }

    private async waitReady(): Promise<void> {
        const client = createPublicClient({transport: http(this._rpc)});
        const deadline = Date.now() + 60_000;
        let lastErr: unknown;
        while (Date.now() < deadline) {
            try {
                await client.getChainId();
                return;
            } catch (err) {
                lastErr = err;
                await new Promise((r) => setTimeout(r, 500));
            }
        }
        throw new Error(`besu at ${this._rpc} not ready within 60s. Last error: ${String(lastErr)}`);
    }
}
