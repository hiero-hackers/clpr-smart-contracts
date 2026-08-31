import {readFileSync} from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..", "..");
const OUT_DIR = path.join(REPO_ROOT, "out");

/// Load a forge artifact by contract name (`out/<Name>.sol/<Name>.json`).
export function loadArtifact(name: string): {
    abi: readonly unknown[];
    bytecode: `0x${string}`;
    deployedBytecode: `0x${string}`;
} {
    const file = path.join(OUT_DIR, `${name}.sol`, `${name}.json`);
    let raw: string;
    try {
        raw = readFileSync(file, "utf8");
    } catch (err) {
        throw new Error(
            `Artifact for ${name} not found at ${file}. Run \`forge build\` from the repo root first.\nUnderlying: ${String(err)}`
        );
    }
    const parsed = JSON.parse(raw) as {
        abi: readonly unknown[];
        bytecode?: {object?: `0x${string}`};
        deployedBytecode?: {object?: `0x${string}`};
    };
    if (!parsed.bytecode?.object || parsed.bytecode.object === "0x") {
        throw new Error(`Artifact for ${name} has no deployable bytecode.`);
    }
    if (!parsed.deployedBytecode?.object || parsed.deployedBytecode.object === "0x") {
        throw new Error(`Artifact for ${name} has no deployed (runtime) bytecode.`);
    }
    return {abi: parsed.abi, bytecode: parsed.bytecode.object, deployedBytecode: parsed.deployedBytecode.object};
}
