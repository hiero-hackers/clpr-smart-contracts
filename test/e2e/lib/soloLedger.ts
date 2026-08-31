import {existsSync, readFileSync} from "node:fs";
import path from "node:path";
import {REPO_ROOT} from "../../../script/deploy/artifacts.js";

/// Resolve the Hiero ledger id bytes for `HieroVerifier` deployment / trust anchors.
///
/// Priority: `CLPR_SOLO_LEDGER_ID` / `LEDGER_ID` / `TRUST_ANCHOR` env → `test/verifiers/hiero/fixtures/trustAnchor.bin`.
export function resolveSoloLedgerId(): `0x${string}` {
    const fromEnv =
        process.env.CLPR_SOLO_LEDGER_ID ??
        process.env.LEDGER_ID ??
        process.env.TRUST_ANCHOR;
    if (fromEnv) {
        return (fromEnv.startsWith("0x") ? fromEnv : `0x${fromEnv}`) as `0x${string}`;
    }
    const file = path.join(REPO_ROOT, "test", "verifiers", "hiero", "fixtures", "trustAnchor.bin");
    if (existsSync(file)) {
        return `0x${readFileSync(file).toString("hex")}` as `0x${string}`;
    }
    throw new Error(
        "Solo ledger id required: set CLPR_SOLO_LEDGER_ID (or LEDGER_ID / TRUST_ANCHOR), " +
        "or add test/verifiers/hiero/fixtures/trustAnchor.bin"
    );
}
