// Gas regression gate.
//
// Reads benchmark.yaml, runs the forge gas benchmarks, and fails (exit 1) if any
// measured value exceeds its baseline by more than `tolerance_pct`. Baselines are
// upper bounds: optimizations that *reduce* gas always pass — only increases fail.
//
//   npm run gas:check            # check (CI gate)
//   npm run gas:check:update     # rewrite baselines to measured
//
//   (or directly:  tsx script/gas/check-gas-regression.ts [--update])
//
// Two metric kinds:
//   * log_benchmarks      — values printed via console.log ("Label: <gas>")
//   * gas_report_benchmarks — a function row from `forge test --gas-report`,
//                             keyed by contract + function + column (contract-aware,
//                             so e.g. ClprService.submitBundle is not confused with
//                             BundleLogic.submitBundle).

import {execFileSync} from "node:child_process";
import {readFileSync, writeFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import path from "node:path";
import YAML from "yaml";

type Column = "min" | "avg" | "median" | "max" | "calls";

interface LogBenchmark {
    name: string;
    match_path: string;
    metrics: Record<string, number>;
}

interface GasReportBenchmark {
    name: string;
    match_path: string;
    contract: string;
    function: string;
    column?: Column;
    baseline: number;
}

interface BenchmarkConfig {
    tolerance_pct?: number;
    log_benchmarks?: LogBenchmark[];
    gas_report_benchmarks?: GasReportBenchmark[];
}

interface CheckResult {
    name: string;
    baseline: number;
    actual: number | null;
    limit: number | null;
    ok: boolean;
    missing?: boolean;
    yamlPath?: (string | number)[];
}

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const YAML_PATH = path.join(REPO_ROOT, "script", "gas", "baselines.yml");
const UPDATE = process.argv.includes("--update-baselines");

const stripAnsi = (s: string): string => s.replace(/\[[0-9;]*[A-Za-z]/g, "");

function runForge(args: string[]): string {
    try {
        return execFileSync("forge", args, {cwd: REPO_ROOT, encoding: "utf8", maxBuffer: 256 * 1024 * 1024});
    } catch (err) {
        // forge exits non-zero if any test fails; still capture stdout so we can
        // surface a useful message instead of a bare throw.
        const e = err as {stdout?: string; stderr?: string};
        const out = `${e.stdout ?? ""}${e.stderr ?? ""}`;
        throw new Error(`forge ${args.join(" ")} failed:\n${out.slice(-2000)}`);
    }
}

/// Parse `console.log("<label>:", value)` lines → Map<normalizedLabel, gas>.
function parseLogs(stdout: string): Map<string, number> {
    const found = new Map<string, number>();
    for (const raw of stripAnsi(stdout).split("\n")) {
        const i = raw.indexOf(":");
        if (i < 0) continue;
        const label = raw.slice(0, i).trim().replace(/\s+/g, " ");
        const rhs = raw.slice(i + 1).trim();
        if (/^\d+$/.test(rhs) && label.length > 0) found.set(label, Number(rhs));
    }
    return found;
}

// Indices into the 5-number tail [min, avg, median, max, calls] (name cell dropped).
const COLS: Record<Column, number> = {min: 0, avg: 1, median: 2, max: 3, calls: 4};

/// Parse a `--gas-report` table, contract-aware → Map<"Contract::fn", number[]>.
function parseGasReport(stdout: string): Map<string, number[]> {
    const rows = new Map<string, number[]>();
    let contract: string | null = null;
    for (const raw of stripAnsi(stdout).split("\n")) {
        const line = raw.trim();
        if (!line.startsWith("|")) continue;
        const header = line.match(/:([A-Za-z0-9_]+)\s+Contract\b/);
        if (header) {
            contract = header[1];
            continue;
        }
        const cells = line.split("|").map((c) => c.trim()).filter((c) => c.length > 0);
        // Function row: name + 5 integer columns (min, avg, median, max, calls).
        if (cells.length >= 6 && contract && /^[A-Za-z_]/.test(cells[0]) && cells.slice(1, 6).every((c) => /^\d+$/.test(c))) {
            rows.set(`${contract}::${cells[0]}`, cells.slice(1, 6).map(Number));
        }
    }
    return rows;
}

const doc = YAML.parseDocument(readFileSync(YAML_PATH, "utf8"));
const cfg = doc.toJS() as BenchmarkConfig;
const tol = Number(cfg.tolerance_pct ?? 0) / 100;

const results: CheckResult[] = [];

// ── log_benchmarks ─────────────────────────────────────────────────────────
for (const [bi, bench] of (cfg.log_benchmarks ?? []).entries()) {
    const out = runForge(["test", "--match-path", bench.match_path, "-vv"]);
    const found = parseLogs(out);
    for (const label of Object.keys(bench.metrics)) {
        const baseline = Number(bench.metrics[label]);
        const actual = found.get(label.replace(/\s+/g, " "));
        if (actual === undefined) {
            results.push({name: `${bench.name} › ${label}`, baseline, actual: null, limit: null, ok: false, missing: true});
            continue;
        }
        const limit = Math.floor(baseline * (1 + tol));
        results.push({
            name: `${bench.name} › ${label}`,
            baseline, actual, limit, ok: actual <= limit,
            yamlPath: ["log_benchmarks", bi, "metrics", label]
        });
    }
}

// ── gas_report_benchmarks (group by match_path → one forge run each) ─────────
const groups = new Map<string, Array<GasReportBenchmark & {idx: number}>>();
for (const [i, m] of (cfg.gas_report_benchmarks ?? []).entries()) {
    if (!groups.has(m.match_path)) groups.set(m.match_path, []);
    groups.get(m.match_path)!.push({...m, idx: i});
}
for (const [matchPath, metrics] of groups) {
    const rows = parseGasReport(runForge(["test", "--match-path", matchPath, "--gas-report"]));
    for (const m of metrics) {
        const baseline = Number(m.baseline);
        const col = COLS[m.column ?? "max"];
        const row = rows.get(`${m.contract}::${m.function}`);
        const actual = row ? row[col] : undefined;
        if (actual === undefined) {
            results.push({name: m.name, baseline, actual: null, limit: null, ok: false, missing: true});
            continue;
        }
        const limit = Math.floor(baseline * (1 + tol));
        results.push({
            name: m.name,
            baseline, actual, limit, ok: actual <= limit,
            yamlPath: ["gas_report_benchmarks", m.idx, "baseline"]
        });
    }
}

// ── --update: rewrite baselines and exit ─────────────────────────────────────
if (UPDATE) {
    let changed = 0;
    for (const r of results) {
        if (r.actual == null || !r.yamlPath) continue;
        if (r.actual !== r.baseline) {
            doc.setIn(r.yamlPath, r.actual);
            changed++;
        }
    }
    writeFileSync(YAML_PATH, doc.toString());
    console.log(`Updated ${changed} baseline(s) in benchmark.yaml from measured values.`);
    process.exit(0);
}

// ── Report ───────────────────────────────────────────────────────────────────
const pad = (s: string | number, n: number): string => String(s).padEnd(n);
const padL = (s: string | number, n: number): string => String(s).padStart(n);
console.log(`\nGas regression check  (tolerance ${(tol * 100).toFixed(2)}%)\n`);
console.log(`  ${pad("metric", 52)} ${padL("baseline", 11)} ${padL("actual", 11)} ${padL("limit", 11)}  status`);
console.log(`  ${"-".repeat(52)} ${"-".repeat(11)} ${"-".repeat(11)} ${"-".repeat(11)}  ------`);
let failed = 0;
for (const r of results) {
    if (r.missing) {
        failed++;
        console.log(`  ${pad(r.name, 52)} ${padL(r.baseline, 11)} ${padL("MISSING", 11)} ${padL("-", 11)}  ❌ not found`);
        continue;
    }
    const delta = r.actual! - r.baseline;
    const sign = delta > 0 ? `+${delta}` : `${delta}`;
    if (!r.ok) failed++;
    console.log(
        `  ${pad(r.name, 52)} ${padL(r.baseline, 11)} ${padL(r.actual!, 11)} ${padL(r.limit!, 11)}  ${r.ok ? "✅" : "❌"} ${sign}`
    );
}
console.log("");
if (failed > 0) {
    console.error(`✗ ${failed} metric(s) regressed or missing. Gas must not increase above baseline.`);
    console.error(`  If the change is intentional, re-baseline with:  npm run gas:check:update`);
    process.exit(1);
}
console.log(`✓ all ${results.length} gas metrics within baseline.`);
