import {readFile, writeFile} from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {loadSoloGlobalConfig, stakeAmountsFor, type SoloSide} from "./config.ts";

const FALCON_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "falcon");

function baseFalconValuesPath(side: SoloSide): string {
    return path.join(FALCON_DIR, side === "a" ? "falcon-a.yaml" : "falcon-b.yaml");
}

/** Absolute path to falcon values with stake amounts matching consensusNodeCount. */
export async function falconValuesPath(side: SoloSide): Promise<string> {
    const basePath = baseFalconValuesPath(side);
    const {consensusNodeCount} = loadSoloGlobalConfig();
    if (consensusNodeCount <= 1) {
        return basePath;
    }

    const stake = stakeAmountsFor(consensusNodeCount);
    let content = await readFile(basePath, "utf8");
    if (/^\s*--stake-amounts:/m.test(content)) {
        content = content.replace(/^\s*--stake-amounts:.*$/m, `  --stake-amounts: "${stake}"`);
    } else {
        content = content.replace(
            /(consensusNode:\n(?:  .+\n)*)/,
            `$1  --stake-amounts: "${stake}"\n`
        );
    }

    const generatedPath = path.join(FALCON_DIR, `.falcon-${side}.generated.yaml`);
    await writeFile(generatedPath, content, "utf8");
    return generatedPath;
}

/** Helm values for mirror web3 EVM chain id (mirrorNode.--values-file). */
export function falconMirrorValuesPath(side: SoloSide): string {
    return path.join(FALCON_DIR, side === "a" ? "mirror-values-a.yaml" : "mirror-values-b.yaml");
}

/** Consensus application.properties overrides (network.--application-properties). */
export function falconNetworkApplicationPropertiesPath(): string {
    return path.join(FALCON_DIR, "network-application-tss.properties");
}
