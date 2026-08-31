import {existsSync, readFileSync} from "node:fs";
import os from "node:os";
import path from "node:path";
import {deploymentFor, type SoloSide} from "../backend/solo/config.ts";
import {resolveMirrorUrl} from "../backend/solo/state.ts";

/// Resolve mirror REST base URL for Hiero proof helpers.
///
/// Priority:
///   1. `CLPR_SOLO_MIRROR_URL` / `CLPR_SOLO_MIRROR_URL_{A|B}`
///   2. `.solo-state/mirror-{side}.url` (written by `e2e:solo:up`)
///   3. `~/.solo/one-shot-{deployment}/forwards` Mirror ingress line
export async function resolveSoloMirrorBaseUrl(side: SoloSide = "b"): Promise<string | undefined> {
    const explicit =
        process.env.CLPR_SOLO_MIRROR_URL ??
        process.env[side === "a" ? "CLPR_SOLO_MIRROR_URL_A" : "CLPR_SOLO_MIRROR_URL_B"];
    if (explicit) return explicit.replace(/\/$/, "");

    const cached = await resolveMirrorUrl(side);
    if (cached) return cached.replace(/\/$/, "");

    const deployment = deploymentFor(side);
    const forwards = path.join(os.homedir(), ".solo", `one-shot-${deployment}`, "forwards");
    if (!existsSync(forwards)) return undefined;

    const text = readFileSync(forwards, "utf8");
    const line = text.split("\n").find((l) => /mirror/i.test(l) && /127\.0\.0\.1|localhost/.test(l));
    if (!line) return undefined;

    const m = line.match(/(https?:\/\/[^\s]+|127\.0\.0\.1:\d+|localhost:\d+)/i);
    if (!m) return undefined;

    const raw = m[1];
    return raw.startsWith("http") ? raw.replace(/\/$/, "") : `http://${raw}`;
}
