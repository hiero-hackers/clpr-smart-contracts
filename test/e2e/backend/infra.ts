#!/usr/bin/env node
/// Infrastructure lifecycle CLI — start/stop external nodes for a given CLPR_BACKEND spec.
///
/// Usage:
///   node --experimental-strip-types test/e2e/backend/infra.ts up   [spec]
///   node --experimental-strip-types test/e2e/backend/infra.ts down  [spec]
///   node --experimental-strip-types test/e2e/backend/infra.ts status [spec]
///
/// `spec` is the same format as CLPR_BACKEND (e.g. "besu", "solo", "besu:solo").
/// When omitted, falls back to the CLPR_BACKEND env var (default: "anvil").
///
/// Mixed specs normalize alphabetically by kind (avalanche < anvil < besu < solo).
/// e.g. `solo:besu` and `besu:solo` both start `besu-a` + `solo-b`.
/// Chain A/B order is alphabetical (besu then solo) in tests regardless of spec spelling.

import {execFileSync} from "node:child_process";
import {createPublicClient, http} from "viem";
import {fileURLToPath} from "node:url";
import path from "node:path";
import {parseBackendSpec, parseInfraComponents} from "./Backend.ts";
import {
    BESU_EXTERNAL_RPC_A,
    BESU_EXTERNAL_RPC_B,
    clearBesuRpcUrl,
    writeBesuRpcUrl
} from "./besu/state.ts";
import {
    AVALANCHE_EXTERNAL_RPC_A,
    AVALANCHE_EXTERNAL_RPC_B,
    clearAvalancheRpcUrl,
    writeAvalancheRpcUrl
} from "./avalanche/state.ts";
import {chainIdFor, relayRpcUrlFor, type SoloSide} from "./solo/config.ts";
import {waitForSoloMirrorContractSim} from "./solo/fund.ts";
import {startAuxiliaryPortForwards} from "./solo/portForward.ts";
import {resolveRelayUrl, writeRelayUrl} from "./solo/state.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "../../..");

type Verb = "up" | "down" | "status";
type Side = "a" | "b";

function usage(): never {
    console.error("Usage: infra.ts <up|down|status> [backend-spec]");
    console.error("  spec examples: besu  solo  avalanche  anvil:besu  besu:solo  solo:besu  anvil:avalanche");
    process.exit(1);
}

function run(cmd: string, args: string[], opts?: {cwd?: string; allowFail?: boolean}): void {
    try {
        execFileSync(cmd, args, {stdio: "inherit", cwd: opts?.cwd ?? ROOT});
    } catch (err) {
        if (!opts?.allowFail) throw err;
    }
}

function node(script: string, args: string[], opts?: {allowFail?: boolean}): void {
    run(process.execPath, ["--experimental-strip-types", script, ...args], opts);
}

// ── Besu (Docker Compose) ─────────────────────────────────────────────────────

const COMPOSE_FILE = path.join(__dirname, "docker-compose.yml");
const BESU_RPC: Record<Side, string> = {a: BESU_EXTERNAL_RPC_A, b: BESU_EXTERNAL_RPC_B};
const BESU_SERVICE: Record<Side, string> = {a: "besu-a", b: "besu-b"};
const AVALANCHE_RPC: Record<Side, string> = {a: AVALANCHE_EXTERNAL_RPC_A, b: AVALANCHE_EXTERNAL_RPC_B};
const AVALANCHE_SERVICE: Record<Side, string> = {a: "avalanche-a", b: "avalanche-b"};

async function waitReady(rpc: string, label: string, timeoutMs = 90_000): Promise<void> {
    const client = createPublicClient({transport: http(rpc)});
    const deadline = Date.now() + timeoutMs;
    let lastErr: unknown;
    process.stdout.write(`  waiting for ${label}...`);
    while (Date.now() < deadline) {
        try {
            await client.getChainId();
            process.stdout.write(" ready\n");
            return;
        } catch (err) {
            lastErr = err;
            await new Promise((r) => setTimeout(r, 500));
        }
    }
    process.stdout.write(" timed out\n");
    throw new Error(`${label} at ${rpc} not ready within ${timeoutMs / 1000}s. Last error: ${String(lastErr)}`);
}

async function besuUp(sides: Side[]): Promise<void> {
    const services = sides.map((s) => BESU_SERVICE[s]);
    console.log(`[besu] starting ${services.join(", ")}...`);
    run("docker", ["compose", "-f", COMPOSE_FILE, "up", "-d", ...services]);

    await Promise.all(sides.map((s) => waitReady(BESU_RPC[s], BESU_SERVICE[s])));
    await Promise.all(sides.map((s) => writeBesuRpcUrl(s, BESU_RPC[s])));

    for (const s of sides) {
        console.log(`[besu] ${BESU_SERVICE[s]} ready at ${BESU_RPC[s]}`);
    }
}

async function besuDown(sides: Side[]): Promise<void> {
    const services = sides.map((s) => BESU_SERVICE[s]);
    console.log(`[besu] stopping ${services.join(", ")}...`);
    await Promise.all(sides.map((s) => clearBesuRpcUrl(s)));
    if (sides.length === 2) {
        run("docker", ["compose", "-f", COMPOSE_FILE, "down", "-v"]);
    } else {
        run("docker", ["compose", "-f", COMPOSE_FILE, "stop", ...services]);
        run("docker", ["compose", "-f", COMPOSE_FILE, "rm", "-f", ...services]);
    }
}

function besuStatus(): void {
    run("docker", ["compose", "-f", COMPOSE_FILE, "ps"], {allowFail: true});
}

// ── Avalanche (Docker Compose) ────────────────────────────────────────────────

async function avalancheUp(sides: Side[]): Promise<void> {
    const services = sides.map((s) => AVALANCHE_SERVICE[s]);
    console.log(`[avalanche] starting ${services.join(", ")}...`);
    run("docker", ["compose", "-f", COMPOSE_FILE, "up", "-d", ...services]);

    await Promise.all(sides.map((s) => waitReady(AVALANCHE_RPC[s], AVALANCHE_SERVICE[s], 120_000)));
    await Promise.all(sides.map((s) => writeAvalancheRpcUrl(s, AVALANCHE_RPC[s])));

    for (const s of sides) {
        console.log(`[avalanche] ${AVALANCHE_SERVICE[s]} ready at ${AVALANCHE_RPC[s]}`);
    }
}

async function avalancheDown(sides: Side[]): Promise<void> {
    const services = sides.map((s) => AVALANCHE_SERVICE[s]);
    console.log(`[avalanche] stopping ${services.join(", ")}...`);
    await Promise.all(sides.map((s) => clearAvalancheRpcUrl(s)));
    if (sides.length === 2) {
        run("docker", ["compose", "-f", COMPOSE_FILE, "down", "-v"]);
    } else {
        run("docker", ["compose", "-f", COMPOSE_FILE, "stop", ...services]);
        run("docker", ["compose", "-f", COMPOSE_FILE, "rm", "-f", ...services]);
    }
}

function avalancheStatus(): void {
    run("docker", ["compose", "-f", COMPOSE_FILE, "ps"], {allowFail: true});
}

// ── Solo (hiero-solo CLI) ─────────────────────────────────────────────────────

const soloCliPath = path.join(__dirname, "solo/cli.ts");

async function probeSoloRelay(side: SoloSide): Promise<string | null> {
    const url = (await resolveRelayUrl(side)) ?? relayRpcUrlFor(side);
    try {
        const id = await createPublicClient({transport: http(url)}).getChainId();
        if (Number(id) === chainIdFor(side)) return url;
    } catch { /* not reachable */ }
    return null;
}

async function soloUpSide(side: SoloSide): Promise<void> {
    const already = await probeSoloRelay(side);
    if (already) {
        console.log(`[solo] solo-${side} already reachable at ${already} — ensuring mirror/block-node forwards`);
        await writeRelayUrl(side, already);
        await startAuxiliaryPortForwards(side);
        return;
    }
    console.log(`[solo] solo-${side} not running — starting via cli.ts...`);
    node(soloCliPath, ["up", side]);
}

async function soloUp(sides: SoloSide[]): Promise<void> {
    for (const s of sides) await soloUpSide(s);
    await Promise.all(sides.map(async (s) => {
        process.stdout.write(`  [solo] waiting for Mirror Node web3 (side ${s})...`);
        await waitForSoloMirrorContractSim(s);
        process.stdout.write(" ready\n");
    }));
}

function soloDown(sides: SoloSide[]): void {
    for (const s of sides) {
        console.log(`[solo] stopping solo-${s}...`);
        node(soloCliPath, ["down", s]);
    }
}

function soloStatus(): void {
    node(soloCliPath, ["status"], {allowFail: true});
}

// ── Main ─────────────────────────────────────────────────────────────────────

const [, , verbArg, specArg] = process.argv;
if (!verbArg || !["up", "down", "status"].includes(verbArg)) usage();
const verb = verbArg as Verb;

const spec = specArg ?? process.env.CLPR_BACKEND ?? "anvil";
if (specArg) process.env.CLPR_BACKEND = specArg;

const {besu: besuSides, solo: soloSides} = parseInfraComponents(spec);
const {kindA, kindB} = parseBackendSpec(spec);
const avalancheSides: Side[] = [
    ...(kindA === "avalanche" ? ["a" as Side] : []),
    ...(kindB === "avalanche" ? ["b" as Side] : [])
];
const hasAnvil = kindA === "anvil" || kindB === "anvil";

if (verb === "status") {
    if (hasAnvil) console.log("[anvil] no persistent nodes — spawns inline during tests.");
    if (besuSides.length) besuStatus();
    if (avalancheSides.length) avalancheStatus();
    if (soloSides.length) soloStatus();
} else if (verb === "up") {
    if (hasAnvil) console.log("[anvil] nothing to do — spawns inline during tests.");
    if (besuSides.length) await besuUp(besuSides);
    if (avalancheSides.length) await avalancheUp(avalancheSides);
    if (soloSides.length) await soloUp(soloSides);
} else {
    if (soloSides.length) soloDown(soloSides);
    if (avalancheSides.length) await avalancheDown(avalancheSides);
    if (besuSides.length) await besuDown(besuSides);
    if (hasAnvil) console.log("[anvil] nothing to do — spawns inline during tests.");
}
