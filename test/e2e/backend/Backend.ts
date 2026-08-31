/// Backend driver abstraction: Driver wraps two ChainNodes (AnvilNode, BesuNode, SoloNode).
/// Tests never know which backend is running — they only see RPC URLs.

export interface Backend {
    /// Spin up both chains (A=1337, B=1338) and wait for them to be RPC-ready.
    start(): Promise<void>;

    /// Tear everything down. Honors CLPR_KEEP_NODES=1 to skip teardown.
    stop(): Promise<void>;

    /// JSON-RPC URL for chain A (local chainId 1337).
    rpcA(): string;

    /// JSON-RPC URL for chain B (local chainId 1338).
    rpcB(): string;

    /// Chain ID strings exactly as `_config.chainId` will be set in the ClprService.
    /// Format follows CAIP-2 ("eip155:<id>"). Passed to viem deploy as `caipChainId`.
    caipA(): string;

    caipB(): string;

    /// Which backend kind drives chain A / chain B.
    kindA(): BackendKind;
    kindB(): BackendKind;

    /// Dev-chain funder for chain A (Anvil/Besu account #0; Solo ecdsa-alias).
    fundedKeyA(): `0x${string}`;

    /// Dev-chain funder for chain B.
    fundedKeyB(): `0x${string}`;

    /// True if the backend supports evm_snapshot / evm_revert (Anvil yes, Besu/Solo no).
    supportsSnapshots(): boolean;
}

export const BACKEND_KINDS = [
    "anvil",
    "besu",
    "solo",
    "avalanche",
    "sei",
] as const;

export type BackendKind = typeof BACKEND_KINDS[number];

export type InfraSide = "a" | "b";

export interface BackendSpec {
    kindA: BackendKind;
    kindB: BackendKind;
}

/// Canonical `CLPR_BACKEND` for mixed Besu + Solo (chain A = besu, chain B = solo).
export const CANONICAL_MIXED_BESU_SOLO = "besu:solo";

const BACKEND_KIND_ORDER: readonly BackendKind[] = ["avalanche", "anvil", "besu", "solo", "sei"];

/// True when the normalized spec is Besu on A and Solo on B.
export function isMixedBesuSolo(raw?: string): boolean {
    const {kindA, kindB} = parseBackendSpec(raw);
    return kindA === "besu" && kindB === "solo";
}

/// Parse CLPR_BACKEND env var. Accepts "anvil", "besu", "solo", "avalanche" (symmetric)
/// or "a:b" for mixed backends, e.g. "besu:solo", "anvil:avalanche".
///
/// Mixed specs normalize alphabetically by kind (avalanche < anvil < besu < solo):
/// chain A gets the earlier kind, chain B the later. `solo:besu` and `besu:solo` are equivalent.
export function parseBackendSpec(raw?: string): BackendSpec {
    const spec = raw ?? process.env.CLPR_BACKEND ?? "anvil";
    const parts = spec.toLowerCase().split(":");
    if (parts.length === 1) {
        const kind = validateKind(parts[0], spec);
        return {kindA: kind, kindB: kind};
    }
    if (parts.length === 2) {
        const left = validateKind(parts[0], spec);
        const right = validateKind(parts[1], spec);
        return normalizeMixedKinds(left, right);
    }
    throw new Error(`CLPR_BACKEND must be "${BACKEND_KINDS.join('", "')}" or "a:b" (got "${spec}")`);
}

/// Which Besu/Solo sides to start for infra up/down (uses normalized chain A/B assignment).
export function parseInfraComponents(raw?: string): {besu: InfraSide[]; solo: InfraSide[]} {
    const {kindA, kindB} = parseBackendSpec(raw);
    const besu: InfraSide[] = [];
    const solo: InfraSide[] = [];
    if (kindA === "besu") besu.push("a");
    if (kindB === "besu") besu.push("b");
    if (kindA === "solo") solo.push("a");
    if (kindB === "solo") solo.push("b");
    return {besu, solo};
}

function normalizeMixedKinds(kindA: BackendKind, kindB: BackendKind): BackendSpec {
    if (kindA === kindB) return {kindA, kindB};
    const order = (k: BackendKind) => BACKEND_KIND_ORDER.indexOf(k);
    return order(kindA) <= order(kindB) ? {kindA, kindB} : {kindA: kindB, kindB: kindA};
}

function validateKind(s: string, raw: string): BackendKind {
    if (!(BACKEND_KINDS as readonly string[]).includes(s)) {
        throw new Error(`Unknown backend kind "${s}" in CLPR_BACKEND="${raw}"`);
    }
    return s as BackendKind;
}
