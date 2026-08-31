#!/usr/bin/env npx tsx
/**
 * Safe Smart Account deployment CLI (viem).
 *
 * Usage:
 *   npx tsx script/deploy/multisig/cliSafe.ts <mode> --rpc-url <url|alias>
 *
 * Modes: all | account
 */
import path from "node:path";
import {privateKeyToAccount} from "viem/accounts";
import {REPO_ROOT} from "../artifacts.js";
import {makeDeployClients} from "../client.js";
import {
    assertSafeDeployment,
    deploySafeAccount,
    deploySafeFull,
} from "./deploySafeAccount.js";
import { MANAGED_KEYS, safeDeployedToEnv} from "./envFile.js";
import {resolveRpcUrl} from "../rpc.js";
import { loadSafeDeployParams, SafeFullDeployment, SafeAccountDeployment, loadSafeDeploymentFromEnv } from "./safeConfig.js";
import { loadDotEnv } from "../envFile.js";
import { normalizePk, requireEnv } from "../shared/helpers.js";

/// all: Singleton + Factory + Proxy
/// account: Proxy
type Mode = "all" | "account"

function usage(): string {
    return `usage: tsx script/deploy/multisig/cliSafe.ts <all|account> --rpc-url <url|anvil|besu|hiero> [--env-file <path>]`;
}

function parseArgs(argv: string[]): {mode: Mode; rpcUrl: string; envFile: string} {
    const positional = argv.filter((a) => !a.startsWith("-"));
    const mode = positional[0] as Mode | undefined;
    if (!mode || !["all", "account"].includes(mode)) {
        throw new Error(usage());
    }
    let rpcUrl = "";
    let envFile = path.join(REPO_ROOT, ".env");
    for (let i = 1; i < argv.length; i++) {
        if (argv[i] === "--rpc-url" && argv[i + 1]) {
            rpcUrl = resolveRpcUrl(argv[++i]);
        } else if (argv[i]?.startsWith("--rpc-url=")) {
            rpcUrl = resolveRpcUrl(argv[i].slice("--rpc-url=".length));
        } else if (argv[i] === "--env-file" && argv[i + 1]) {
            envFile = argv[++i]!;
        } else if (argv[i]?.startsWith("--env-file=")) {
            envFile = argv[i].slice("--env-file=".length);
        }
    }
    if (!rpcUrl) throw new Error(`${usage()}\nmissing --rpc-url`);
    return {mode, rpcUrl, envFile};
}

function logFullSafeDeployed(modules: SafeFullDeployment): void {
    console.error("Deployed in this run:");
    console.error(`  Singleton → ${modules.singleton} (env: SAFE_SINGLETON)`);
    console.error(`  SafeProxyFactory → ${modules.factory} (env: SAFE_FACTORY)`);
    console.error(`  SafeAccount → ${modules.account} (env: OWNER_ACCOUNT)`);
}

function logSafeAccountDeployed(run: SafeAccountDeployment): void {
    console.error(`  SafeAccount → ${run.account} (env: OWNER_ACCOUNT)`);
}

async function main(): Promise<void> {
    const {mode, rpcUrl, envFile} = parseArgs(process.argv.slice(2));
    loadDotEnv(envFile);

    switch (mode) {
        case "all":
            requireEnv(["PRIVATE_KEY"], envFile);
            break;
        case "account":
            requireEnv(["PRIVATE_KEY"], envFile);
            requireEnv(["SAFE_SINGLETON"], envFile);
            requireEnv(["SAFE_FACTORY"], envFile);
            break;
    }

    const pk = normalizePk(envFile);
    const deployer = privateKeyToAccount(pk).address;

    const clients = await makeDeployClients({rpcUrl, privateKey: pk});
    const params = loadSafeDeployParams(pk);
    let exports: Partial<Record<(typeof MANAGED_KEYS)[number], string>> = {};

    switch (mode) {
        case "all": {
            const safeDeployment = await deploySafeFull(clients, params);
            const env = safeDeployedToEnv(safeDeployment);
            logFullSafeDeployed(safeDeployment);
            exports = env;
            break;
        }
        case "account": {
            const modules = loadSafeDeploymentFromEnv();
            await assertSafeDeployment(clients, modules);
            const accountDeployment = await deploySafeAccount(
                clients,
                modules.singleton,
                modules.factory,
                params
            );

            const env = safeDeployedToEnv(accountDeployment);
            logSafeAccountDeployed(accountDeployment);
            exports = env;
            break;
        }
    }

    for (const [k, v] of Object.entries(exports)) {
        if (v) console.log(`export ${k}=${v}`);
    }
}

main().catch((err) => {
    console.error(String(err));
    process.exit(1);
});
