import {execSync, spawn} from "node:child_process";
import {
    clusterRefFor,
    deploymentFor,
    kindClusterFor,
    kubectlContextFor,
    namespaceFor,
    type SoloSide
} from "./config.ts";
import {resolveDeploymentNamespace} from "./deployInfo.ts";
import {runSolo, soloLog} from "./exec.ts";

function kindClusterNames(): Set<string> {
    try {
        const out = execSync("kind get clusters", {encoding: "utf8", stdio: ["pipe", "pipe", "ignore"]});
        return new Set(out.split("\n").map((l) => l.trim()).filter(Boolean));
    } catch {
        return new Set();
    }
}

function kubectlContexts(): Set<string> {
    try {
        const out = execSync("kubectl config get-contexts -o name", {encoding: "utf8", stdio: ["pipe", "pipe", "ignore"]});
        return new Set(out.split("\n").map((l) => l.trim()).filter(Boolean));
    } catch {
        return new Set();
    }
}

function deleteKubectlContext(ctx: string): void {
    try {
        execSync(`kubectl config delete-context ${ctx}`, {stdio: "ignore"});
        soloLog(`removed stale kubectl context ${ctx}`);
    } catch {
        // already gone
    }
}

function runKind(args: string[]): Promise<void> {
    return new Promise((resolve, reject) => {
        const proc = spawn("kind", args, {stdio: "inherit"});
        proc.on("error", reject);
        proc.on("exit", (code) =>
            code === 0 ? resolve() : reject(new Error(`kind ${args.join(" ")} exited ${code}`))
        );
    });
}

/** Create the Kind cluster for this side when it is not running (ignore orphaned kubeconfig contexts). */
export async function ensureKindCluster(side: SoloSide): Promise<void> {
    const ctx = kubectlContextFor(side);
    const name = kindClusterFor(side);
    if (kindClusterNames().has(name)) {
        soloLog(`side ${side}: kind cluster ${name} running`);
        return;
    }
    if (kubectlContexts().has(ctx)) {
        deleteKubectlContext(ctx);
    }
    soloLog(`side ${side}: creating kind cluster ${name} (context ${ctx})`);
    await runKind(["create", "cluster", "--name", name]);
}

/** Solo one-shot uses kubectl's current context; set it before deploy and port-forwards. */
export function useKubectlContext(side: SoloSide): void {
    const ctx = kubectlContextFor(side);
    execSync(`kubectl config use-context ${ctx}`, {stdio: "ignore"});
    soloLog(`side ${side}: kubectl context ${ctx}`);
}

/** Map Solo cluster-ref to this side's dedicated Kind context (not shared kind-solo-cluster). */
export async function connectClusterRef(
    side: SoloSide,
    env: NodeJS.ProcessEnv = process.env
): Promise<void> {
    const clusterRef = clusterRefFor(side);
    const ctx = kubectlContextFor(side);
    soloLog(`side ${side}: cluster-ref ${clusterRef} -> context ${ctx}`);
    await runSolo(["cluster-ref", "config", "connect", "-c", clusterRef, "--context", ctx, "-q"], env);
}

/** Solo `deployment config info` reflects kubectl current-context, not per-deployment — compare namespace only. */
export async function deploymentUsesExpectedNamespace(
    side: SoloSide,
    env: NodeJS.ProcessEnv = process.env
): Promise<boolean> {
    try {
        const ns = await resolveDeploymentNamespace(deploymentFor(side), env);
        return ns === namespaceFor(side);
    } catch {
        return false;
    }
}
