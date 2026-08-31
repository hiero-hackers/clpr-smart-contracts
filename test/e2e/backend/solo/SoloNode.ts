import type {ChainNode} from "../ChainNode.js";
import {chainIdFor} from "./config.js";
import {loadSoloFunderKey} from "./fund.js";
import {resolveRelayUrl} from "./state.js";
import {ensureSoloE2ERelays} from "./solo.js";

/// External Solo network (started via `npm run e2e:up:solo`). The JSON-RPC relay
/// is EVM-compatible. `slot` selects which of the two Solo clusters to use.
export class SoloNode implements ChainNode {
    private _rpc = "";
    private _fundedKey: `0x${string}` | null = null;

    /// `slot`: "a" → solo-a cluster, chainId 1337
    ///         "b" → solo-b cluster, chainId 1338
    constructor(private readonly slot: "a" | "b") {}

    private get chainId() { return chainIdFor(this.slot); }

    kind() { return "solo" as const; }
    rpc() {
        if (!this._rpc) throw new Error(`SoloNode(${this.slot}) not started`);
        return this._rpc;
    }
    caip() { return `eip155:${this.chainId}`; }
    fundedKey() {
        if (!this._fundedKey) throw new Error("Solo funder not loaded — run e2e:up:solo");
        return this._fundedKey;
    }
    supportsSnapshots() { return false; }

    async start(): Promise<void> {
        await ensureSoloE2ERelays([this.slot]);

        const envKey = process.env.CLPR_SOLO_FUNDED_KEY as `0x${string}` | undefined;
        this._rpc = (await resolveRelayUrl(this.slot)) ?? process.env[`SOLO_RPC_${this.slot.toUpperCase()}`] ?? "";
        if (!this._rpc) throw new Error(`Solo relay URL for slot ${this.slot} missing — run npm run e2e:up:solo`);
        this._fundedKey = envKey ?? (await loadSoloFunderKey(this.slot));
    }

    async stop(): Promise<void> {
        if (process.env.CLPR_KEEP_NODES === "1") {
            console.log(`[solo] CLPR_KEEP_NODES=1 — solo-${this.slot} stays up until npm run e2e:down:solo`);
        }
    }
}
