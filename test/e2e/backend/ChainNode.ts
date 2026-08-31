import type {BackendKind} from "./Backend.js";

/// A single-chain node. No concept of "side A" or "side B" — that pairing is
/// done at the Driver level. Each node just knows its own RPC URL, kind, and
/// funded key once started.
export interface ChainNode {
    kind(): BackendKind;

    /// JSON-RPC endpoint (populated after start()).
    rpc(): string;

    /// CAIP-2 chain identifier, e.g. "eip155:1337".
    caip(): string;

    /// A pre-funded private key for sending transactions on this chain.
    fundedKey(): `0x${string}`;

    /// True if the chain supports evm_snapshot / evm_revert (Anvil only).
    supportsSnapshots(): boolean;

    /// Bring the chain up (idempotent if already running).
    start(): Promise<void>;

    /// Tear down the chain.
    stop(): Promise<void>;
}
