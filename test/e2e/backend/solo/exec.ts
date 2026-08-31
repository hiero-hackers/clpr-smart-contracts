import {spawn} from "node:child_process";
import path from "node:path";
import {fileURLToPath} from "node:url";

const REPO_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "../../../..");

export function soloLog(msg: string): void {
    console.error(`[solo] ${msg}`);
}

export async function runSolo(args: string[], env: NodeJS.ProcessEnv): Promise<void> {
    const label = `npx @hiero-ledger/solo ${args.join(" ")}`;
    soloLog(label);
    return new Promise((resolve, reject) => {
        let stderr = "";
        const proc = spawn("npx", ["@hiero-ledger/solo", ...args], {
            cwd: REPO_ROOT,
            env,
            stdio: process.env.CLPR_LOG === "trace" ? "inherit" : ["ignore", "pipe", "pipe"]
        });
        proc.stderr?.on("data", (c: Buffer) => {
            stderr += c.toString();
            if (process.env.CLPR_LOG !== "silent") process.stderr.write(c);
        });
        proc.stdout?.on("data", (c: Buffer) => {
            if (process.env.CLPR_LOG !== "silent") process.stdout.write(c);
        });
        proc.on("error", reject);
        proc.on("exit", (code) => {
            if (code === 0) resolve();
            else reject(new Error(`${label} exited ${code}${stderr ? `\n${stderr.trim()}` : ""}`));
        });
    });
}

/** Run solo and return combined stdout/stderr (for parsing `deployment config info`). */
export async function runSoloOutput(args: string[], env: NodeJS.ProcessEnv): Promise<string> {
    const label = `npx @hiero-ledger/solo ${args.join(" ")}`;
    return new Promise((resolve, reject) => {
        let out = "";
        const proc = spawn("npx", ["@hiero-ledger/solo", ...args], {
            cwd: REPO_ROOT,
            env,
            stdio: ["ignore", "pipe", "pipe"]
        });
        const append = (c: Buffer) => {
            out += c.toString();
        };
        proc.stdout?.on("data", append);
        proc.stderr?.on("data", append);
        proc.on("error", reject);
        proc.on("exit", (code) => {
            if (code === 0) resolve(out);
            else reject(new Error(`${label} exited ${code}${out ? `\n${out.trim()}` : ""}`));
        });
    });
}
