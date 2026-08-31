import {readFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const SOLO_HOME = path.join(os.homedir(), ".solo");

/** Solo writes `~/.solo/one-shot-<deployment>/forwards` after deploy. */
export function soloOneShotDir(deployment: string): string {
    return path.join(SOLO_HOME, `one-shot-${deployment}`);
}

export function soloAccountsPath(deployment: string): string {
    return path.join(soloOneShotDir(deployment), "accounts.json");
}

/** `JSON RPC Relay port forward enabled on 127.0.0.1:37546` */
export function parseRelayRpcUrl(forwardsText: string): string {
    const match = forwardsText.match(/JSON RPC Relay port forward enabled on (127\.0\.0\.1:\d+)/);
    if (!match) {
        throw new Error("forwards file missing JSON RPC Relay line");
    }
    return `http://${match[1]}`;
}

export async function readRelayRpcFromDeployment(deployment: string): Promise<string> {
    const text = await readFile(path.join(soloOneShotDir(deployment), "forwards"), "utf8");
    return parseRelayRpcUrl(text);
}

interface SoloAccountsFile {
    createdAccounts?: Array<{group?: string; privateKey?: string}>;
}

export function parseEcdsaAliasKey(accountsPath: string, raw: string): `0x${string}` {
    const doc = JSON.parse(raw) as SoloAccountsFile;
    const row = doc.createdAccounts?.find(
        (a) => a.group === "ecdsa-alias" && a.privateKey?.startsWith("0x")
    );
    if (!row?.privateKey) {
        throw new Error(`no ecdsa-alias account in ${accountsPath}`);
    }
    return row.privateKey as `0x${string}`;
}
