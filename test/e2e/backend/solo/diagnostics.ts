#!/usr/bin/env node
/// Solo E2E diagnostics for CI artifacts / local debugging (relay + mirror web3 path).
///
/// Usage:
///   node --experimental-strip-types test/e2e/backend/solo/diagnostics.ts [backend-spec|a|b]
///
/// Writes a log file to CLPR_DIAGNOSTICS_DIR or test/e2e/backend/.solo-state/diagnostics/.

import {execSync} from "node:child_process";
import {readFile} from "node:fs/promises";
import {mkdir, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {createPublicClient, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {parseInfraComponents} from "../Backend.ts";
import {parseEcdsaAliasKey, soloAccountsPath} from "./artifacts.ts";
import {
    chainIdFor,
    deploymentFor,
    kubectlContextFor,
    loadSoloGlobalConfig,
    mirrorPortFor,
    mirrorRestUrlFor,
    namespaceFor,
    relayPortFor,
    relayRpcUrlFor,
    type SoloSide
} from "./config.ts";
import {resolveDeploymentNamespace} from "./deployInfo.ts";
import {runSoloOutput} from "./exec.ts";
import {listListenersOnPort} from "./portForward.ts";
import {mirrorUrlFile, readMirrorUrl, readRelayUrl, relayUrlFile} from "./state.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_OUT_DIR = path.join(__dirname, "../.solo-state/diagnostics");
const LOG_TAIL = 300;

function soloEnv(side: SoloSide): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = {...process.env, SOLO_CHAIN_ID: String(chainIdFor(side))};
    if (loadSoloGlobalConfig().enableBlockNode) {
        env.ONE_SHOT_WITH_BLOCK_NODE = "true";
    }
    if (!env.CONSENSUS_NODE_VERSION) {
        env.CONSENSUS_NODE_VERSION = "v0.74.0";
    }
    return env;
}

function capture(label: string, cmd: string): string {
    try {
        const out = execSync(cmd, {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
            maxBuffer: 32 * 1024 * 1024
        });
        return out.trimEnd();
    } catch (err: unknown) {
        const e = err as {stderr?: string; stdout?: string; message?: string};
        const detail = (e.stderr || e.stdout || e.message || String(err)).trimEnd();
        return `${label} failed:\n${detail}`;
    }
}

async function probeRelay(rpc: string, expected: number): Promise<string> {
    try {
        const chainId = Number(await createPublicClient({transport: http(rpc)}).getChainId());
        return chainId === expected
            ? `eth_chainId ok: ${chainId}`
            : `eth_chainId mismatch: got ${chainId}, expected ${expected}`;
    } catch (err) {
        return `eth_chainId probe failed: ${String(err)}`;
    }
}

async function probeRelayEstimateGas(
    rpc: string,
    from: `0x${string}`,
    to: `0x${string}`
): Promise<string> {
    try {
        const gas = await createPublicClient({transport: http(rpc)}).estimateGas({
            account: from,
            to,
            value: 1n
        });
        return `eth_estimateGas (1 wei self-transfer) ok: ${gas}`;
    } catch (err) {
        return `eth_estimateGas failed: ${String(err)}`;
    }
}

async function probeHttp(label: string, url: string, init?: RequestInit): Promise<string> {
    try {
        const res = await fetch(url, init);
        const body = await res.text();
        const snippet = body.length > 800 ? `${body.slice(0, 800)}…` : body;
        return `${label}: HTTP ${res.status}\n${snippet}`;
    } catch (err) {
        return `${label} failed: ${String(err)}`;
    }
}

async function loadFunderAddress(deployment: string): Promise<`0x${string}` | undefined> {
    const accountsPath = soloAccountsPath(deployment);
    try {
        const raw = await readFile(accountsPath, "utf8");
        const key = parseEcdsaAliasKey(accountsPath, raw);
        return privateKeyToAccount(key).address;
    } catch (err) {
        return undefined;
    }
}

function mirrorIngressHost(ns: string): string {
    return `mirror-ingress-controller-${ns}.${ns}.svc.cluster.local`;
}

function inClusterCurl(
    ctx: string,
    ns: string,
    label: string,
    url: string,
    method: "GET" | "POST" = "GET",
    jsonBody?: string
): string {
    const pod = `solo-diag-${Date.now()}`;
    const bodyArg = jsonBody ? `-d ${JSON.stringify(jsonBody)}` : "";
    const cmd = [
        `kubectl --context ${ctx} run ${pod}`,
        `--rm -i --restart=Never -n ${ns}`,
        `--image=curlimages/curl:8.5.0`,
        `--command --`,
        `sh -c ${JSON.stringify(
            `curl -sS -w '\\nHTTP:%{http_code}\\n' -X ${method} -H 'Content-Type: application/json' ${bodyArg} ${JSON.stringify(url)}`
        )}`
    ].join(" ");
    return capture(`in-cluster ${label}`, cmd);
}

function mirrorComponentLogs(
    ctx: string,
    ns: string,
    label: string,
    selector: string
): string {
    return capture(
        `${label} logs`,
        `kubectl --context ${ctx} logs -n ${ns} -l ${selector} --tail=${LOG_TAIL} --all-containers=true`
    );
}

async function diagnoseMirrorProbes(
    side: SoloSide,
    lines: string[],
    funder?: `0x${string}`
): Promise<void> {
    const mirrorPort = mirrorPortFor(side);
    const mirrorListeners = listListenersOnPort(mirrorPort);
    const mirrorUrl = (await readMirrorUrl(side)) ?? mirrorRestUrlFor(side);
    const relayUrl = (await readRelayUrl(side)) ?? relayRpcUrlFor(side);

    lines.push("");
    lines.push("--- mirror / relay live probes (from runner) ---");
    lines.push(`mirror port ${mirrorPort}: listeners=${mirrorListeners.length} pids=[${mirrorListeners.join(", ")}]`);
    lines.push(`mirror state ${mirrorUrlFile(side)}: ${mirrorUrl}`);
    lines.push(
        await probeHttp(
            "mirror REST GET /api/v1/blocks",
            `${mirrorUrl}/api/v1/blocks?limit=1&order=desc`
        )
    );
    lines.push(
        await probeHttp("mirror REST GET /api/v1/network/exchangerate", `${mirrorUrl}/api/v1/network/exchangerate`)
    );
    if (funder) {
        lines.push(
            await probeHttp(
                `mirror REST GET /api/v1/accounts/${funder}`,
                `${mirrorUrl}/api/v1/accounts/${funder}?transactions=false`
            )
        );
        lines.push(`relay ${relayUrl}: ${await probeRelayEstimateGas(relayUrl, funder, funder)}`);
        lines.push(
            "note: eth_estimateGas uses relay → mirror web3 POST /api/v1/contracts/call (not mirror-1-rest port-forward)"
        );
    } else {
        lines.push("funder address unavailable (accounts.json missing) — skipping account + estimateGas probes");
    }
}

async function diagnoseMirrorInCluster(
    ctx: string,
    ns: string,
    lines: string[],
    funder?: `0x${string}`
): Promise<void> {
    const ingress = `http://${mirrorIngressHost(ns)}`;
    const web3Svc = `http://mirror-1-web3.${ns}.svc.cluster.local`;
    const restSvc = `http://mirror-1-rest.${ns}.svc.cluster.local`;

    lines.push("");
    lines.push("--- mirror in-cluster HTTP probes (ephemeral curl pod) ---");
    lines.push(inClusterCurl(ctx, ns, "ingress blocks", `${ingress}/api/v1/blocks?limit=1&order=desc`));
    lines.push(inClusterCurl(ctx, ns, "web3 svc blocks", `${web3Svc}/api/v1/blocks?limit=1&order=desc`));
    lines.push(inClusterCurl(ctx, ns, "rest svc blocks", `${restSvc}/api/v1/blocks?limit=1&order=desc`));

    if (funder) {
        const callBody = JSON.stringify({
            estimate: true,
            from: funder,
            to: funder,
            gas: 800_000,
            gasPrice: 100_000_000,
            value: 0,
            data: "0x"
        });
        lines.push(
            inClusterCurl(
                ctx,
                ns,
                "ingress contracts/call (simulation)",
                `${ingress}/api/v1/contracts/call`,
                "POST",
                callBody
            )
        );
        lines.push(
            inClusterCurl(
                ctx,
                ns,
                "web3 svc contracts/call (simulation)",
                `${web3Svc}/api/v1/contracts/call`,
                "POST",
                callBody
            )
        );
    }
}

async function diagnoseSide(side: SoloSide, lines: string[]): Promise<void> {
    const env = soloEnv(side);
    const ctx = kubectlContextFor(side);
    const deployment = deploymentFor(side);
    const ns = namespaceFor(side);
    const relayPort = relayPortFor(side);
    const expectedChain = chainIdFor(side);
    const defaultRpc = relayRpcUrlFor(side);
    const cachedRpc = await readRelayUrl(side);
    const listeners = listListenersOnPort(relayPort);
    const funder = await loadFunderAddress(deployment);

    lines.push(`=== Solo side ${side.toUpperCase()} ===`);
    lines.push(`deployment=${deployment} namespace=${ns} context=${ctx}`);
    lines.push(`relay port ${relayPort}: listeners=${listeners.length} pids=[${listeners.join(", ")}]`);
    lines.push(`state file ${relayUrlFile(side)}: ${cachedRpc ?? "(missing)"}`);
    lines.push(`RPC probe ${cachedRpc ?? defaultRpc}: ${await probeRelay(cachedRpc ?? defaultRpc, expectedChain)}`);
    if (funder) lines.push(`ecdsa-alias funder: ${funder}`);

    await diagnoseMirrorProbes(side, lines, funder);

    lines.push("");
    lines.push("--- solo deployment config info ---");
    try {
        lines.push(await runSoloOutput(["deployment", "config", "info", "-d", deployment, "-q"], env));
    } catch (err) {
        lines.push(`deployment config info failed: ${String(err)}`);
    }

    lines.push("");
    lines.push("--- solo deployment diagnostics channels ---");
    lines.push(
        capture(
            "solo channels",
            `npx @hiero-ledger/solo deployment diagnostics channels -d ${deployment} -q`
        )
    );

    let resolvedNs = ns;
    try {
        resolvedNs = await resolveDeploymentNamespace(deployment, env);
    } catch {
        // use default namespace from config
    }

    await diagnoseMirrorInCluster(ctx, resolvedNs, lines, funder);

    lines.push("");
    lines.push(`--- kubectl pods/svc (${ctx}/${resolvedNs}) ---`);
    lines.push(capture("kubectl pods", `kubectl --context ${ctx} get pods -n ${resolvedNs} -o wide`));
    lines.push(capture("kubectl svc", `kubectl --context ${ctx} get svc -n ${resolvedNs}`));
    lines.push(
        capture(
            "kubectl events (mirror/relay)",
            `kubectl --context ${ctx} get events -n ${resolvedNs} --sort-by=.lastTimestamp | grep -E 'mirror|relay|importer|web3' | tail -60`
        )
    );
    lines.push(
        capture(
            "kubectl events (recent)",
            `kubectl --context ${ctx} get events -n ${resolvedNs} --sort-by=.lastTimestamp | tail -40`
        )
    );

    lines.push("");
    lines.push("--- relay service / pod ---");
    lines.push(capture("relay svc", `kubectl --context ${ctx} describe svc relay-1 -n ${resolvedNs}`));
    lines.push(
        capture(
            "relay pods",
            `kubectl --context ${ctx} get pods -n ${resolvedNs} -l app.kubernetes.io/name=relay -o wide`
        )
    );
    lines.push(mirrorComponentLogs(ctx, resolvedNs, "relay", "app.kubernetes.io/name=relay"));
    lines.push(
        capture(
            "relay describe",
            `kubectl --context ${ctx} describe pods -n ${resolvedNs} -l app.kubernetes.io/name=relay`
        )
    );

    lines.push("");
    lines.push("--- mirror stack (relay eth_estimateGas → web3 contracts/call) ---");
    lines.push(
        capture(
            "mirror pods (all)",
            `kubectl --context ${ctx} get pods -n ${resolvedNs} | grep -E '^mirror-'`
        )
    );
    lines.push(
        capture(
            "mirror ingress",
            `kubectl --context ${ctx} describe svc mirror-ingress-controller-${resolvedNs} -n ${resolvedNs}`
        )
    );
    lines.push(
        capture(
            "mirror ingress describe pod",
            `kubectl --context ${ctx} describe pods -n ${resolvedNs} -l app.kubernetes.io/name=ingress`
        )
    );
    lines.push(mirrorComponentLogs(ctx, resolvedNs, "mirror REST", "app.kubernetes.io/name=rest"));
    lines.push(mirrorComponentLogs(ctx, resolvedNs, "mirror web3", "app.kubernetes.io/name=web3"));
    lines.push(mirrorComponentLogs(ctx, resolvedNs, "mirror importer", "app.kubernetes.io/name=importer"));
    lines.push(mirrorComponentLogs(ctx, resolvedNs, "mirror restjava", "app.kubernetes.io/name=restjava"));
    lines.push(mirrorComponentLogs(ctx, resolvedNs, "mirror grpc", "app.kubernetes.io/name=grpc"));
    lines.push(
        capture(
            "mirror web3 describe",
            `kubectl --context ${ctx} describe pods -n ${resolvedNs} -l app.kubernetes.io/name=web3`
        )
    );
    lines.push(
        capture(
            "mirror importer describe",
            `kubectl --context ${ctx} describe pods -n ${resolvedNs} -l app.kubernetes.io/name=importer`
        )
    );
    lines.push(
        capture(
            "mirror postgres",
            `kubectl --context ${ctx} get pods -n ${resolvedNs} -l app.kubernetes.io/name=postgresql -o wide`
        )
    );
    lines.push(
        capture(
            "consensus nodes",
            `kubectl --context ${ctx} get pods -n ${resolvedNs} -l app.kubernetes.io/name=network-node -o wide`
        )
    );
}

function resolveSides(arg?: string): SoloSide[] {
    if (arg === "a" || arg === "b") return [arg];
    const spec = arg ?? process.env.CLPR_BACKEND ?? "solo";
    const {solo} = parseInfraComponents(spec);
    return solo.length > 0 ? solo : (["a", "b"] as const);
}

async function main(): Promise<void> {
    const sides = resolveSides(process.argv[2]);
    const outDir = process.env.CLPR_DIAGNOSTICS_DIR ?? DEFAULT_OUT_DIR;
    await mkdir(outDir, {recursive: true});

    const lines: string[] = [];
    lines.push("=== Runner ===");
    lines.push(`time=${new Date().toISOString()}`);
    lines.push(
        `cpus=${os.cpus().length} totalMemMiB=${Math.round(os.totalmem() / 1024 / 1024)} freeMemMiB=${Math.round(os.freemem() / 1024 / 1024)}`
    );
    lines.push(capture("free", "free -h"));
    lines.push(capture("df", "df -h /"));
    lines.push(capture("docker", "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"));
    lines.push(capture("kind", "kind get clusters"));

    const soloLog = path.join(os.homedir(), ".solo/logs/solo.log");
    lines.push("");
    lines.push(`--- solo log tail (${soloLog}) ---`);
    lines.push(capture("solo.log", `tail -n 200 ${JSON.stringify(soloLog)}`));

    for (const side of sides) {
        lines.push("");
        await diagnoseSide(side, lines);
    }

    const body = `${lines.join("\n")}\n`;
    const outFile = path.join(outDir, `solo-mirror-${Date.now()}.log`);
    await writeFile(outFile, body, "utf8");
    await writeFile(path.join(outDir, "latest.log"), body, "utf8");
    process.stdout.write(body);
    console.error(`\n[diagnostics] wrote ${outFile}`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
