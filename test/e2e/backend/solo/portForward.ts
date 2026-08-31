import {execSync} from "node:child_process";
import {spawn} from "node:child_process";
import net from "node:net";
import {mkdir, readFile, rm, writeFile} from "node:fs/promises";
import {createPublicClient, http} from "viem";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {
    blockNodePortFor,
    chainIdFor,
    deploymentFor,
    kubectlContextFor,
    loadSoloGlobalConfig,
    mirrorPortFor,
    relayPortFor,
    type SoloSide
} from "./config.ts";
import {resolveDeploymentNamespace} from "./deployInfo.ts";
import {soloLog} from "./exec.ts";
import {writeBlockNodeUrl, writeMirrorUrl} from "./state.ts";

const STATE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "../.solo-state");
const RELAY_SVC = "svc/relay-1";
const RELAY_POD_PORT = "7546";
const MIRROR_SVC = "svc/mirror-1-rest";
const MIRROR_POD_PORT = "80";
const BLOCK_NODE_SVC = "svc/block-node-1";
const BLOCK_NODE_POD_PORT = "40840";

// Mirror Node deployments to wait for. The relay has its own port-forward probe (eth_chainId).
// The importer is the critical one: it populates the database that mirror-1-web3 reads for
// eth_estimateGas simulation — if the importer is still starting up, web3 returns 500.
const MIRROR_DEPLOYMENTS = ["mirror-1-importer", "mirror-1-grpc", "mirror-1-rest", "mirror-1-web3"];

function pfPidFile(side: SoloSide, kind: "relay" | "mirror" | "block-node"): string {
    return path.join(STATE_DIR, `${kind}-${side}.pf.pid`);
}

/** TCP connect probe — enough to verify kubectl port-forward is listening (no gRPC client needed). */
function probeTcpPort(port: number, host = "127.0.0.1"): Promise<void> {
    return new Promise((resolve, reject) => {
        const socket = net.connect({host, port}, () => {
            socket.destroy();
            resolve();
        });
        socket.setTimeout(3_000);
        socket.on("timeout", () => {
            socket.destroy();
            reject(new Error(`tcp probe timeout ${host}:${port}`));
        });
        socket.on("error", reject);
    });
}

/** PIDs listening on `127.0.0.1:port` / `[::1]:port` (kubectl port-forward). */
export function listListenersOnPort(port: number): number[] {
    try {
        const out = execSync(`lsof -nP -iTCP:${port} -sTCP:LISTEN`, {encoding: "utf8", stdio: ["pipe", "pipe", "ignore"]});
        const pids = new Set<number>();
        for (const line of out.split("\n")) {
            const m = line.trim().match(/^(\S+)\s+(\d+)\s/);
            if (m) pids.add(Number(m[2]));
        }
        return [...pids].filter((pid) => pid > 0 && pid !== process.pid);
    } catch {
        return [];
    }
}

function killPid(pid: number, signal: NodeJS.Signals): void {
    try {
        process.kill(pid, signal);
    } catch {
        // ESRCH
    }
}

/** Stop any process bound to the relay local port (orphaned kubectl forwards). */
export function releaseLocalRelayPort(port: number): void {
    const pids = listListenersOnPort(port);
    if (pids.length === 0) return;

    for (const pid of pids) killPid(pid, "SIGTERM");
    soloLog(`released local port ${port} (pids: ${pids.join(", ")})`);

    const remaining = listListenersOnPort(port);
    for (const pid of remaining) killPid(pid, "SIGKILL");
    if (remaining.length > 0) {
        soloLog(`force-released local port ${port} (pids: ${remaining.join(", ")})`);
    }
}

async function stopPortForward(side: SoloSide, kind: "relay" | "mirror" | "block-node"): Promise<void> {
    try {
        const pid = Number((await readFile(pfPidFile(side, kind), "utf8")).trim());
        if (pid > 0) killPid(pid, "SIGTERM");
    } catch {
        // no pid file
    }
    await rm(pfPidFile(side, kind), {force: true});

    const port =
        kind === "relay" ? relayPortFor(side) :
        kind === "mirror" ? mirrorPortFor(side) :
        blockNodePortFor(side);
    releaseLocalRelayPort(port);
}

export async function stopRelayPortForward(side: SoloSide): Promise<void> {
    await stopPortForward(side, "relay");
}

async function stopAuxiliaryPortForwards(side: SoloSide): Promise<void> {
    await stopPortForward(side, "mirror");
    await stopPortForward(side, "block-node");
}

export async function stopAllPortForwards(): Promise<void> {
    for (const side of ["a", "b"] as const) {
        await stopRelayPortForward(side);
        await stopAuxiliaryPortForwards(side);
    }
}

/** @deprecated use stopAllPortForwards */
export async function stopAllRelayPortForwards(): Promise<void> {
    await stopAllPortForwards();
}

async function waitService(ctx: string, ns: string, svc: string): Promise<void> {
    const name = svc.replace(/^svc\//, "");
    const deadline = Date.now() + 300_000;
    let lastLog = 0;
    while (Date.now() < deadline) {
        try {
            await runKubectl(["--context", ctx, "get", "svc", name, "-n", ns]);
            return;
        } catch {
            if (Date.now() - lastLog > 30_000) {
                soloLog(`waiting for ${name} svc in ${ctx}/${ns}…`);
                lastLog = Date.now();
            }
            await new Promise((r) => setTimeout(r, 2_000));
        }
    }
    throw new Error(`${name} service not found in ${ctx}/${ns}`);
}

async function startPortForward(opts: {
    side: SoloSide;
    kind: "relay" | "mirror" | "block-node";
    env: NodeJS.ProcessEnv;
    svc: string;
    podPort: string;
    localPort: number;
    probe?: () => Promise<void>;
}): Promise<void> {
    const {side, kind, env, svc, podPort, localPort, probe} = opts;
    const ctx = kubectlContextFor(side);
    const ns = await resolveDeploymentNamespace(deploymentFor(side), env);

    await stopPortForward(side, kind);
    await waitService(ctx, ns, svc);

    const existing = listListenersOnPort(localPort);
    if (existing.length > 0) {
        throw new Error(
            `local port ${localPort} still in use after cleanup (pids: ${existing.join(", ")})`
        );
    }

    soloLog(`side ${side}: kubectl port-forward ${svc} ${localPort}:${podPort} (${ctx}/${ns})`);
    const proc = spawn(
        "kubectl",
        ["--context", ctx, "port-forward", "-n", ns, svc, `${localPort}:${podPort}`],
        {stdio: "ignore", detached: true}
    );
    proc.unref();

    if (!proc.pid) throw new Error(`kubectl port-forward failed to start (${kind}, side ${side})`);
    await mkdir(STATE_DIR, {recursive: true});
    await writeFile(pfPidFile(side, kind), `${proc.pid}\n`, "utf8");

    if (probe) {
        const deadline = Date.now() + 60_000;
        while (Date.now() < deadline) {
            try {
                await probe();
                return;
            } catch {
                await new Promise((r) => setTimeout(r, 500));
            }
        }
        throw new Error(`${kind} port-forward on 127.0.0.1:${localPort} did not become reachable`);
    }
}

export async function startRelayPortForward(
    side: SoloSide,
    env: NodeJS.ProcessEnv = process.env
): Promise<void> {
    const localPort = relayPortFor(side);
    const expected = chainIdFor(side);
    const rpc = `http://127.0.0.1:${localPort}`;

    await startPortForward({
        side,
        kind: "relay",
        env,
        svc: RELAY_SVC,
        podPort: RELAY_POD_PORT,
        localPort,
        probe: async () => {
            const chainId = Number(await createPublicClient({transport: http(rpc)}).getChainId());
            if (chainId !== expected) throw new Error(`eth_chainId ${chainId} !== ${expected}`);
        }
    });
}

async function waitMirrorDeploymentsReady(ctx: string, ns: string): Promise<void> {
    soloLog(`waiting for mirror node deployments to be ready (${ctx}/${ns})…`);
    await Promise.all(
        MIRROR_DEPLOYMENTS.map((dep) =>
            runKubectl([
                "--context", ctx,
                "rollout", "status",
                "-n", ns,
                `deployment/${dep}`,
                "--timeout=300s"
            ])
        )
    );
    soloLog(`mirror node deployments ready (${ctx}/${ns})`);
}

/** Mirror REST + block node gRPC (for Hiero state proofs). Skips block node when disabled. */
export async function startAuxiliaryPortForwards(
    side: SoloSide,
    env: NodeJS.ProcessEnv = process.env
): Promise<void> {
    const ctx = kubectlContextFor(side);
    const ns = await resolveDeploymentNamespace(deploymentFor(side), env);
    await waitMirrorDeploymentsReady(ctx, ns);

    const {enableBlockNode} = loadSoloGlobalConfig();
    const mirrorPort = mirrorPortFor(side);
    const mirrorUrl = `http://127.0.0.1:${mirrorPort}`;

    await startPortForward({
        side,
        kind: "mirror",
        env,
        svc: MIRROR_SVC,
        podPort: MIRROR_POD_PORT,
        localPort: mirrorPort,
        probe: async () => {
            const res = await fetch(`${mirrorUrl}/api/v1/blocks?limit=1`);
            if (!res.ok) throw new Error(`mirror probe ${res.status}`);
        }
    });
    await writeMirrorUrl(side, mirrorUrl);

    if (!enableBlockNode) return;

    const blockPort = blockNodePortFor(side);
    const blockNodeGrpc = `127.0.0.1:${blockPort}`;
    await startPortForward({
        side,
        kind: "block-node",
        env,
        svc: BLOCK_NODE_SVC,
        podPort: BLOCK_NODE_POD_PORT,
        localPort: blockPort,
        probe: () => probeTcpPort(blockPort)
    });
    await writeBlockNodeUrl(side, blockNodeGrpc);
}

/** True when exactly one listener owns the port (healthy single forward). */
export function relayPortForwardHealthy(side: SoloSide): boolean {
    return listListenersOnPort(relayPortFor(side)).length === 1;
}

function runKubectl(args: string[]): Promise<void> {
    return new Promise((resolve, reject) => {
        const proc = spawn("kubectl", args, {stdio: "ignore"});
        proc.on("error", reject);
        proc.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`kubectl ${args.join(" ")} exited ${code}`))));
    });
}
