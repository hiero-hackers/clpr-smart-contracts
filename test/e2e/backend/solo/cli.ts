import {rm} from "node:fs/promises";
import {createPublicClient, http} from "viem";
import {
    chainIdFor,
    clusterRefFor,
    deploymentFor,
    kubectlContextFor,
    loadSoloGlobalConfig,
    namespaceFor,
    relayPortFor,
    relayRpcUrlFor,
    type SoloSide
} from "./config.ts";
import {
    connectClusterRef,
    deploymentUsesExpectedNamespace,
    ensureKindCluster,
    useKubectlContext
} from "./cluster.ts";
import {runSolo, soloLog} from "./exec.ts";
import {falconValuesPath} from "./falconValues.ts";
import {
    listListenersOnPort,
    startAuxiliaryPortForwards,
    startRelayPortForward,
    stopAllPortForwards,
    stopRelayPortForward
} from "./portForward.ts";
import {waitForSoloRelayTransfers} from "./fund.ts";
import {applySoloRpcEnv, relayUrlFile, resolveRelayUrl, writeRelayUrl} from "./state.ts";

type Cmd = "up" | "down" | "status";

function soloArgs(cmd: "deploy" | "destroy", side: SoloSide, valuesFile: string): string[] {
    const args = ["one-shot", "falcon", cmd, "-d", deploymentFor(side), "-q"];
    if (cmd === "deploy") {
        args.push(
            "-c",
            clusterRefFor(side),
            "-n",
            namespaceFor(side),
            "--values-file",
            valuesFile
        );
        const {consensusNodeCount} = loadSoloGlobalConfig();
        if (consensusNodeCount > 1) {
            args.push("--num-consensus-nodes", String(consensusNodeCount));
        }
    }
    return args;
}

function soloEnv(side: SoloSide): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = {...process.env, SOLO_CHAIN_ID: String(chainIdFor(side))};
    if (loadSoloGlobalConfig().enableBlockNode) {
        env.ONE_SHOT_WITH_BLOCK_NODE = "true";
    }
    // Solo 0.77 gates remoteConfig.state.tssEnabled on consensus-node-version (not --release-tag).
    if (!env.CONSENSUS_NODE_VERSION) {
        env.CONSENSUS_NODE_VERSION = "v0.74.0";
    }
    return env;
}

async function probeRpcChainId(rpc: string): Promise<{ok: boolean; chainId?: number}> {
    try {
        const id = Number(await createPublicClient({transport: http(rpc)}).getChainId());
        return {ok: true, chainId: id};
    } catch {
        return {ok: false};
    }
}

async function relayReady(rpc: string, expected: number): Promise<boolean> {
    const p = await probeRpcChainId(rpc);
    return p.ok && p.chainId === expected;
}

async function waitRelay(rpc: string, expected: number, side: SoloSide): Promise<void> {
    const deadline = Date.now() + 600_000;
    while (Date.now() < deadline) {
        if (await relayReady(rpc, expected)) {
            soloLog(`side ${side}: ready at ${rpc} (eth_chainId ${expected})`);
            return;
        }
        await new Promise((r) => setTimeout(r, 2_000));
    }
    throw new Error(`side ${side}: ${rpc} not ready (expected eth_chainId ${expected})`);
}

export async function upSide(side: SoloSide): Promise<void> {
    const expected = chainIdFor(side);
    const rpc = relayRpcUrlFor(side);
    const {consensusNodeCount, enableBlockNode} = loadSoloGlobalConfig();
    const cached = await resolveRelayUrl(side);
    if (cached) {
        const port = relayPortFor(side);
        const listeners = listListenersOnPort(port);
        const deployOk = await deploymentUsesExpectedNamespace(side, soloEnv(side));
        const ready = await relayReady(cached, expected);
        if (ready && listeners.length === 1 && deployOk) {
            soloLog(`side ${side}: already up (${cached}, ${kubectlContextFor(side)}) — ensuring mirror/block-node forwards`);
            await startAuxiliaryPortForwards(side, soloEnv(side));
            return;
        }
        if (!deployOk) {
            soloLog(
                `side ${side}: deployment namespace mismatch (expected ${namespaceFor(side)}) — redeploying`
            );
        }
        if (listeners.length > 1) {
            soloLog(`side ${side}: ${listeners.length} port-forwards on :${port} — recycling`);
        } else if (ready) {
            soloLog(`side ${side}: relay ok but port-forward missing — restarting forward`);
        } else {
            soloLog(`side ${side}: relay not ready at ${cached}`);
        }
        await stopRelayPortForward(side);
    }

    const env = soloEnv(side);
    await ensureKindCluster(side);
    useKubectlContext(side);
    await connectClusterRef(side, env);
    soloLog(
        `side ${side}: falcon deploy (${consensusNodeCount} consensus nodes` +
        `${enableBlockNode ? ", block node" : ""}, chainId ${expected}, ns ${namespaceFor(side)}, ctx ${kubectlContextFor(side)})`
    );
    await deploySide(side);
    useKubectlContext(side);
    await startRelayPortForward(side, env);
    await startAuxiliaryPortForwards(side, env);
    await writeRelayUrl(side, rpc);
    await waitRelay(rpc, expected, side);
    await waitForSoloRelayTransfers(side);
}

async function runFalconDeploy(side: SoloSide): Promise<void> {
    useKubectlContext(side);
    const valuesFile = await falconValuesPath(side);
    await runSolo(soloArgs("deploy", side, valuesFile), soloEnv(side));
}

async function deploySide(side: SoloSide): Promise<void> {
    try {
        await runFalconDeploy(side);
    } catch (err) {
        const msg = String(err);
        if (!/component exists|already exists/i.test(msg)) throw err;
        soloLog(`side ${side}: stale deployment — destroy and retry deploy`);
        await runSolo(soloArgs("destroy", side, ""), soloEnv(side)).catch(() => {});
        await runFalconDeploy(side);
    }
}

export async function downSide(side: SoloSide): Promise<void> {
    await stopRelayPortForward(side);
    soloLog(`side ${side}: falcon destroy`);
    await runSolo(soloArgs("destroy", side, ""), soloEnv(side)).catch((e: unknown) => {
        soloLog(`destroy warning: ${e}`);
    });
    await rm(relayUrlFile(side), {force: true});
}

export async function upAll(): Promise<void> {
    await upSide("a");
    await upSide("b");
    await applySoloRpcEnv();
}

export async function downAll(): Promise<void> {
    await downSide("a");
    await downSide("b");
    await stopAllPortForwards();
}

export async function status(): Promise<boolean> {
    await applySoloRpcEnv();
    let ok = true;
    for (const side of ["a", "b"] as const) {
        const rpc = (await resolveRelayUrl(side)) ?? relayRpcUrlFor(side);
        const expected = chainIdFor(side);
        const p = await probeRpcChainId(rpc);
        const port = relayPortFor(side);
        const listeners = listListenersOnPort(port);
        const pfOk = listeners.length === 1;
        const ready = p.ok && p.chainId === expected && pfOk;
        const pfNote =
            listeners.length === 0 ? "no port-forward" : listeners.length > 1 ? `${listeners.length} port-forwards` : "ok";
        const ethNote = p.ok ? String(p.chainId) : "unreachable";
        const deployOk = await deploymentUsesExpectedNamespace(side).catch(() => false);
        const ctx = deployOk ? kubectlContextFor(side) : `${kubectlContextFor(side)}?`;
        console.log(
            `side ${side.toUpperCase()}  ${rpc}  chainId=${expected}  eth_chainId=${ethNote}  ctx=${ctx}  ${ready ? "ready" : "not ready"}  pf:${pfNote}`
        );
        if (!ready) ok = false;
    }
    return ok;
}

async function main(): Promise<void> {
    const cmd = process.argv[2] as Cmd | undefined;
    const sideArg = process.argv[3] as SoloSide | undefined;
    if (cmd === "up") {
        if (sideArg === "a" || sideArg === "b") await upSide(sideArg);
        else await upAll();
        return;
    }
    if (cmd === "down") {
        if (sideArg === "a" || sideArg === "b") await downSide(sideArg);
        else await downAll();
        return;
    }
    if (cmd === "status") {
        process.exit((await status()) ? 0 : 1);
    }
    console.error("usage: solo/cli.ts <up|down|status> [a|b]");
    process.exit(2);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
