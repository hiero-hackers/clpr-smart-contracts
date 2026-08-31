import {readFileSync, writeFileSync} from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import type {Hex} from "viem";
import {loadDotEnv} from "../../../script/deploy/envFile.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
export const INPUTS_DIR = path.join(REPO_ROOT, "test", "verifiers", "hiero", "fixtures");
export const CHANNEL_FILE = path.join(REPO_ROOT, "test", "verification-inputs", ".channel.json");
export const STATE_PROOF_BIN = path.join(INPUTS_DIR, "stateProof.bin");
export const STATE_PROOF_JSON = path.join(INPUTS_DIR, "stateProof.json");

export interface ChannelRecord {
    channelId: Hex;
    operatorPrivateKey: Hex;
    operatorPubKey: Hex;
    operatorAddress: Hex;
    salt: Hex;
    hieroVerifier: Hex;
    localChainId: string;
    peerChainId: string;
    clprService: Hex;
    createdAt: string;
}

loadDotEnv(path.join(REPO_ROOT, ".env"));

export function requireEnv(name: string): string {
    const v = process.env[name];
    if (!v) throw new Error(`Missing required env var ${name} (set in .env or the shell)`);
    return v;
}

export function envHex(name: string, fallback?: Hex): Hex {
    const v = process.env[name] ?? fallback;
    if (!v) throw new Error(`Missing hex env var ${name}`);
    return v as Hex;
}

export function envAddress(name: string, fallback?: Hex): Hex {
    return envHex(name, fallback);
}

export const DEFAULT_BESU_A = "http://localhost:53318";
export const DEFAULT_BESU_B = "http://localhost:53317";

export function besuRpcA(): string {
    return process.env.BESU_RPC_A ?? DEFAULT_BESU_A;
}

export function besuRpcB(): string {
    return process.env.BESU_RPC_B ?? DEFAULT_BESU_B;
}

export function clprService(): Hex {
    return envAddress("CLPR_SERVICE", "0x5fc8d32690cc91d4c39d9d3abcbd16989f875707");
}

export function privateKey(): Hex {
    return envHex("PRIVATE_KEY");
}

export function trustAnchorBytes(): Uint8Array {
    const fromFile = path.join(INPUTS_DIR, "trustAnchor.bin");
    if (existsSync(fromFile)) return readFileSync(fromFile);
    const hex = process.env.TRUST_ANCHOR;
    if (hex) {
        const h = hex.startsWith("0x") ? hex.slice(2) : hex;
        return Uint8Array.from(Buffer.from(h, "hex"));
    }
    throw new Error("trustAnchor.bin not found and TRUST_ANCHOR not set");
}

export function trustAnchorHex(): Hex {
    const bytes = trustAnchorBytes();
    return (`0x${Buffer.from(bytes).toString("hex")}`) as Hex;
}

export function stateProofBytes(): Uint8Array {
    if (!existsSync(STATE_PROOF_BIN)) {
        throw new Error(`stateProof.bin not found at ${STATE_PROOF_BIN}`);
    }
    return readFileSync(STATE_PROOF_BIN);
}

export function stateProofJsonExists(): boolean {
    return existsSync(STATE_PROOF_JSON);
}

export function readChannelRecord(): ChannelRecord {
    if (!existsSync(CHANNEL_FILE)) {
        throw new Error(
            `Channel record not found at ${CHANNEL_FILE}. Run establish-channel.ts first.`
        );
    }
    return JSON.parse(readFileSync(CHANNEL_FILE, "utf8")) as ChannelRecord;
}

export function writeChannelRecord(record: ChannelRecord): void {
    writeFileSync(CHANNEL_FILE, `${JSON.stringify(record, null, 2)}\n`, "utf8");
}
