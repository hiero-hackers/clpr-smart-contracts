export type SoloSide = "a" | "b";

export interface SoloSideConfig {
    chainId: number;
    relayPort: number;
    mirrorPort: number;
    blockNodePort: number;
    namespace: string;
    deployment: string;
}

export interface SoloGlobalConfig {
    consensusNodeCount: number;
    enableBlockNode: boolean;
}

const SIDE_DEFAULTS: Record<SoloSide, Pick<SoloSideConfig, "chainId" | "relayPort" | "mirrorPort" | "blockNodePort">> = {
    a: {chainId: 1337, relayPort: 37546, mirrorPort: 39081, blockNodePort: 39100},
    b: {chainId: 1338, relayPort: 37547, mirrorPort: 39082, blockNodePort: 39101}
};

function defaultNamespace(side: SoloSide): string {
    return `clpr-solo-${side}`;
}

/** Solo cluster-ref / Kind cluster name: `{namespace}-cluster`. */
export function clusterRefFromNamespace(namespace: string): string {
    return `${namespace}-cluster`;
}

/** Kind kubeconfig context: `kind-{namespace}-cluster`. */
export function kubectlContextFromNamespace(namespace: string): string {
    return `kind-${clusterRefFromNamespace(namespace)}`;
}

export function deploymentFromNamespace(namespace: string): string {
    return `${namespace}-deployment`;
}

export function soloSideConfig(side: SoloSide): SoloSideConfig {
    const d = SIDE_DEFAULTS[side];
    const suffix = side.toUpperCase();
    const namespace = process.env[`CLPR_SOLO_NAMESPACE_${suffix}`] ?? defaultNamespace(side);
    return {
        chainId: Number(process.env[`CLPR_SOLO_CHAIN_ID_${suffix}`] ?? String(d.chainId)),
        relayPort: Number(process.env[`CLPR_SOLO_RELAY_PORT_${suffix}`] ?? String(d.relayPort)),
        mirrorPort: Number(process.env[`CLPR_SOLO_MIRROR_PORT_${suffix}`] ?? String(d.mirrorPort)),
        blockNodePort: Number(process.env[`CLPR_SOLO_BLOCK_NODE_PORT_${suffix}`] ?? String(d.blockNodePort)),
        namespace,
        deployment: process.env[`CLPR_SOLO_DEPLOYMENT_${suffix}`] ?? deploymentFromNamespace(namespace)
    };
}

export function loadSoloGlobalConfig(): SoloGlobalConfig {
    return {
        consensusNodeCount: Number(process.env.CLPR_SOLO_CONSENSUS_NODES ?? "3"),
        enableBlockNode: process.env.CLPR_SOLO_BLOCK_NODE !== "false"
    };
}

/** Comma-separated stake amounts for falcon consensusNode.--stake-amounts. */
export function stakeAmountsFor(nodeCount: number, amount = 500): string {
    return Array.from({length: nodeCount}, () => String(amount)).join(",");
}

export function chainIdFor(side: SoloSide): number {
    return soloSideConfig(side).chainId;
}

export function deploymentFor(side: SoloSide): string {
    return soloSideConfig(side).deployment;
}

export function clusterRefFor(side: SoloSide): string {
    return clusterRefFromNamespace(namespaceFor(side));
}

export function namespaceFor(side: SoloSide): string {
    return soloSideConfig(side).namespace;
}

export function relayPortFor(side: SoloSide): number {
    return soloSideConfig(side).relayPort;
}

export function mirrorPortFor(side: SoloSide): number {
    return soloSideConfig(side).mirrorPort;
}

export function blockNodePortFor(side: SoloSide): number {
    return soloSideConfig(side).blockNodePort;
}

export function relayRpcUrlFor(side: SoloSide): string {
    return `http://127.0.0.1:${relayPortFor(side)}`;
}

export function mirrorRestUrlFor(side: SoloSide): string {
    return `http://127.0.0.1:${mirrorPortFor(side)}`;
}

export function blockNodeGrpcUrlFor(side: SoloSide): string {
    return `127.0.0.1:${blockNodePortFor(side)}`;
}

export function kindClusterFor(side: SoloSide): string {
    return clusterRefFromNamespace(namespaceFor(side));
}

export function kubectlContextFor(side: SoloSide): string {
    return kubectlContextFromNamespace(namespaceFor(side));
}
