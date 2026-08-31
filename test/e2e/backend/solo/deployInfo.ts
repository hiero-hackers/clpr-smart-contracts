import {runSoloOutput} from "./exec.ts";

/** Namespace from Solo deployment config (`deployment config info`). */
export async function resolveDeploymentNamespace(
    deployment: string,
    env: NodeJS.ProcessEnv = process.env
): Promise<string> {
    const out = await runSoloOutput(["deployment", "config", "info", "-d", deployment, "-q"], env);
    const namespace = out.match(/Namespace:\s*(\S+)/)?.[1];
    if (!namespace) {
        throw new Error(`could not parse namespace for deployment ${deployment}`);
    }
    return namespace;
}
