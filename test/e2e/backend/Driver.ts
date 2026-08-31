import type {Backend} from "./Backend.js";
import type {ChainNode} from "./ChainNode.js";

/// The single top-level driver. Always owns exactly two ChainNodes — one for
/// chain A (chainId 1337) and one for chain B (chainId 1338). The nodes are
/// independent and can be any combination of kinds (anvil, besu, solo).
export class Driver implements Backend {
    constructor(
        private readonly nodeA: ChainNode,
        private readonly nodeB: ChainNode
    ) {}

    kindA() { return this.nodeA.kind(); }
    kindB() { return this.nodeB.kind(); }

    rpcA() { return this.nodeA.rpc(); }
    rpcB() { return this.nodeB.rpc(); }

    caipA() { return this.nodeA.caip(); }
    caipB() { return this.nodeB.caip(); }

    fundedKeyA() { return this.nodeA.fundedKey(); }
    fundedKeyB() { return this.nodeB.fundedKey(); }

    supportsSnapshots() {
        return this.nodeA.supportsSnapshots() && this.nodeB.supportsSnapshots();
    }

    async start(): Promise<void> {
        await Promise.all([this.nodeA.start(), this.nodeB.start()]);
    }

    async stop(): Promise<void> {
        await Promise.all([this.nodeA.stop(), this.nodeB.stop()]);
    }
}
