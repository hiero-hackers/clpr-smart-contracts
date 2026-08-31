# CLAUDE.md

Guidance for Claude Code working in this repository. This file covers project intent, conventions, and procedural guidance that isn't captured in the agent reference docs:

- [`.claude/instructions.md`](.claude/instructions.md) — tech stack, personality, requirements
- [`.claude/build-commands.md`](.claude/build-commands.md) — build, test, coverage, gas, and e2e commands
- [`.claude/directory-structure.md`](.claude/directory-structure.md) — directory-by-directory roles
- [`.claude/conventions.md`](.claude/conventions.md) — coding conventions for this repo
- [`.claude/git-hooks.md`](.claude/git-hooks.md) — required local git hooks (must be installed per clone)
- [`docs/CLPR.md`](docs/CLPR.md) — index of the protocol and verifier documentation
- [`docs/testing.md`](docs/testing.md) — testing guide
- [`.github/workflows/docs/naming-standards.md`](.github/workflows/docs/naming-standards.md) — GitHub Actions filename + workflow-name standard
- [`docs/branch-naming-conventions.md`](docs/branch-naming-conventions.md) — branch, release-branch, and tag naming standard
- [`docs/release-process.md`](docs/release-process.md) — how a release is cut, versioned, packaged, and published

<!-- Auto-load the reference docs above so Claude has them in context from session start. -->
@.claude/instructions.md
@.claude/build-commands.md
@.claude/directory-structure.md
@.claude/conventions.md
@.claude/git-hooks.md

## What this repository is

`clpr-smart-contracts` holds the **CLPR protocol's EVM Solidity contracts**, built with [Foundry](https://book.getfoundry.sh/), together with a viem/TypeScript deploy CLI (`script/deploy/`) and a vitest end-to-end harness (`test/e2e/`) that exercises the contracts against real Anvil, Besu-QBFT, and Hiero Solo backends.

The deliverable is **bytecode deployed to a live chain**. There is no rollback: a `ClprService` that ships with a shifted storage slot, an oversized constructor, or an unverified proof path is a production incident, not a revert-and-redeploy. Correctness, storage discipline, and gas are all first-class review concerns, and the bar for "just make CI green" is deliberately high.

**License**: Apache 2.0 (`LICENSE`). Every `.sol` file carries `// SPDX-License-Identifier: Apache-2.0` on line 1. Do not import a proprietary header from a sibling repository.

## Build, lint, test (one-liner)

```bash
forge build src --deny warnings                      # CI build gate (src only, warnings fatal)
FOUNDRY_PROFILE=test forge build --deny warnings     # test tree (relaxes 3860/5574 size warnings)
forge fmt --check src test script                    # CI format gate
forge test -vvv                                      # full Forge suite
```

Full command surface — coverage floors, gas baselines, storage-layout snapshot, Slither, and the e2e backends — is in `.claude/build-commands.md`. This repo has no Gradle / Hardhat / Spotless toolchain; Foundry and npm are the whole story.

Clone with `--recurse-submodules` (or run `forge install`): `lib/forge-std`, `lib/openzeppelin-contracts`, and `lib/safe-smart-account` are pinned submodules mapped through `remappings.txt`.

## Deploys are the user's action

The agent may run the deploy CLI and `bin/*.sh` wrappers against a **local** backend it started itself — `anvil`, the two-node Besu compose stack, or Solo. It must **never** broadcast to a shared testnet or mainnet RPC, and must never run `cast send` / `forge script --broadcast` / `forge create` against one.

Production deploys, the post-deploy multisig checklist (`initialize(...)` then `setClprEnabled(true)`), signer rotations, and the kill switch are all human-driven — see `README.md`, `docs/safe-runbook.md`, and `docs/runbooks/kill-switch.md`. The agent's role is to prepare the durable git-tracked change and the exact commands, not to execute them.

## When making changes

- **New protocol behaviour**: goes in a logic module under `src/logic/` (extending `src/logic/base/LogicModuleBase.sol`), reached through `ClprService` by `delegatecall`. Pure/internal helpers belong in `src/libraries/` — `service/` for service-side logic, `codec/` for wire encoding, `crypto/` and `proof/` for primitives. Do not grow `ClprService` itself: its constructor already sits near EIP-3860's 49152-byte initcode cap, which is why `AdminLogic` is deployed separately and passed in via the constructor (see the comment block in `foundry.toml`).
- **State changes**: `ClprService` and every logic module share one storage layout (`src/ClprServiceStorage.sol`). Append new state; never insert or reorder. Regenerate the committed snapshot with `forge build && forge inspect ClprService storage-layout --json > storage-layout.json`, using the Foundry version pinned in `.github/workflows/600-flow-pull-request-checks.yaml`, and explain the diff in the PR. CI fails when the snapshot drifts.
- **New verifier**: implement `IClprVerifier` under `src/verifiers/<family>/`, reusing `src/verifiers/evm/common/ClprEvmBundleVerifier.sol` for EVM sources. Proof primitives live in `src/libraries/proof/<family>/`. Add the family's spec to `docs/` alongside `hiero-verifier.md` / `qbft-verifier.md` / `sei-verifier.md`, add it to the conformance suite in `test/verifiers/compliance/`, and wire it into `bin/verifier.sh`.
- **New test fixtures**: proof fixtures live under `test/verifiers/<family>/fixtures/`. The QBFT fixtures are generated by `tools/qbft-proof-generator/` and are gitignored — regenerate rather than commit them.
- **Cutting a release**: never by hand. Dispatch `100: [USER] Publish Contracts` as a dry run, review the computed version and notes, then re-run with `dry-run-enabled` off. Versions are derived from Conventional Commit subjects, so a mislabelled PR title changes the released version. Full procedure in `docs/release-process.md`.
- **Gas-sensitive changes**: run `npm run gas:check`. If a regression is intentional, update `script/gas/baselines.yml` with `npm run gas:check:update` and say why in the PR body.
- **New secret**: never commit a plaintext value. `.env` is gitignored; `.env.example` documents the shape. `PRIVATE_KEY`, `INITIAL_OWNER`, and `OWNER_ACCOUNT` never belong in a commit, a test fixture, or a workflow file — CI-side values come from GitHub Actions secrets.
- **New GitHub Actions workflow**: file under `.github/workflows/` following the naming standard in `.github/workflows/docs/naming-standards.md` (`ddd-xxxx-<name>.yaml`; workflow `name:` is `"ddd: [XXXX] Title"`). Pin every `uses:` to a full SHA with a `# vX.Y.Z` trailing comment, set an explicit `concurrency:` group (`cancel-in-progress: true`), scope `permissions:` to the minimum, add a `harden-runner` step, and run on the `sl-clpr-sc-lin-lg` self-hosted runner. Every existing workflow already complies — see its "Adoption status" table.
- **New branch**: `<issue_number>-<short_desc>` per `docs/branch-naming-conventions.md`.
- **Renaming a CI job**: a required status check's context is the **job** name (or `job (matrix-value)`), so renaming a job — or changing its `name:` — breaks the `[Branch] Layer 4` ruleset and blocks every PR until the ruleset is updated. Renaming a workflow *file* or its `name:` is safe.

## CI/CD

- **`100-user-publish-contracts.yaml`** (`100: [USER] Publish Contracts`) — the release entry point, dispatched manually. Computes the next version from Conventional Commits via `git-semver`, builds, packs a reproducible artifact bundle (ABI + creation/deployed bytecode + storage layout + compiler manifest), verifies the bundle re-packs to an identical checksum, renders release notes, then pushes a **signed** `v<X.Y.Z>` tag and creates the GitHub Release. `dry-run-enabled` defaults to **true** — a run publishes nothing until it is explicitly unchecked. See `docs/release-process.md`.
- **`600-flow-pull-request-checks.yaml`** (`600: [FLOW] PR Checks`) — the main gate, five jobs: `Build` (`forge build src --deny warnings` + `FOUNDRY_PROFILE=test forge build --deny warnings`, uploads `out/`), `Lint` (storage-layout snapshot check + `forge fmt --check src test script`), `Test` (`forge test -vvv`), `Coverage` (`forge coverage`, enforcing floors set as workflow env: lines ≥ 92, statements ≥ 91, branches ≥ 83, functions ≥ 100), and `Deploy Smoke` (runs the deploy CLI end-to-end against a throwaway anvil with a freshly generated funded key).
- **`601-flow-pull-request-formatting.yaml`** (`601: [FLOW] PR Formatting`) — the `Title Check` job, validating the PR title against Conventional Commits via `step-security/action-semantic-pull-request`. Runs on `pull_request_target`, so it executes the copy of the workflow on the **base** branch, not the PR's.
- **`602-flow-e2e-tests.yaml`** (`602: [FLOW] E2E Tests`) — the vitest suite against three backends: `E2E Anvil`, `E2E Besu` (two-node compose stack), and `E2E Solo` (Hiero Solo on kind, with helm/kind/kubectl installed in-job). Each uploads a JUnit artifact.
- **`603-flow-cross-verifier.yaml`** (`603: [FLOW] Cross Verifier`) — the `Besu Hiero Cross Verifier` job: Besu QBFT (chain A) ↔ Hiero EVM via the Solo JSON-RPC relay (chain B), ferrying QBFT state proofs A→B and Hiero `StateProof`s B→A through `submitBundle`. Uses EVM `ClprService` on both sides — not native CLPR and not a dual-Solo stack.
- **`604-flow-gas-benchmark.yaml`** (`604: [FLOW] Gas Benchmark`) — the `Gas Regression` job, against `script/gas/baselines.yml`.
- **`605-flow-slither-scan.yaml`** (`605: [FLOW] Slither Scan`) — the `Slither` job (`fail-on: high`), triaged against `slither-baseline.json`, filtering `lib/`, `test/`, `script/`; publishes a triage markdown artifact.
- **`606-flow-trigger-clpr-e2e.yaml`** (`606: [FLOW] Trigger CLPR E2E`) — the `Dispatch CLPR E2E` job, which dispatches the cross-repo suite in `clpr-e2e` for each non-draft PR and returns immediately; clpr-e2e reports back asynchronously as the `CLPR End-to-End Tests (clpr-e2e repository)` commit status on the PR head. The dispatch block is byte-for-byte identical across every source repo — keep it that way. Needs the `CLPR_E2E_DISPATCH_TOKEN` secret.
- **Workflow naming**: see `.github/workflows/docs/naming-standards.md`. Every workflow follows `ddd-xxxx-<name>.yaml` / `"ddd: [XXXX] Title"`, with short Title Case job names.
- **Hardening**: every job's first step is `step-security/harden-runner` with `egress-policy: audit`. The org-level `Layer 3c` ruleset requires the `StepSecurity Required Checks` status on `main`.
- **Runners**: all workflow jobs run on the `sl-clpr-sc-lin-lg` self-hosted runner.
- **GitHub Actions**: all `uses:` pinned by full SHA with a `# vX.Y.Z` comment.
- **Dependabot**: weekly updates for GitHub Actions dependencies (`.github/dependabot.yml`).
- **PR titles**: Conventional Commits (`feat(234): …`, `fix: …`, `chore(deps): …`). Squash-merge is the default, so the PR title becomes the commit subject.

## Branch protection

| Ruleset | Enforces |
|---------|----------|
| `[Branch] Layer 1: Basic Limits` | No branch creation or deletion, linear history, **signed commits required** |
| `[Branch] Layer 1a: Basic Limits - Force Push` | No force pushes |
| `[Branch] Layer 2: PR Requirements` | PR required, all conversations resolved, **squash-merge only** |
| `[Branch] Layer 3: Basic Status Check Requirements` | `DCO` |
| `[Branch] Layer 4: Test Status Check Requirements` | `Build`, `Lint`, `Test`, `Coverage`, `Deploy Smoke`, `E2E Anvil`, `E2E Besu`, `E2E Solo`, `Slither`, `Gas Regression` |
| `[Branch] Layer 5: PR Formatting Status Check Requirements` | `Title Check` (Conventional Commits, from `601-flow-pull-request-formatting.yaml`) |
| `[Tag] Layer 1: Basic Limits` | Tags immutable and signed |

Consequences for day-to-day work: every commit that lands must be GPG-signed and carry a DCO `Signed-off-by:` trailer (see `.claude/git-hooks.md`), PR titles must be Conventional Commits, and merges are squash-only.

The external `CLPR End-to-End Tests (clpr-e2e repository)` status is deliberately **not** required — `606-flow-trigger-clpr-e2e.yaml` carries `paths-ignore` for `docs/**`, `.github/**`, `test/**`, and `**/*.md`, so it never reports on docs-only PRs and would block them permanently.

## CODEOWNERS

`.github/CODEOWNERS` keeps the ownership split deliberately small:

- The global `*` catch-all is owned by the CLPR maintainers team — contracts, tests, deploy tooling, and docs all fall here.
- `/.github/` (CI configuration and Actions workflows), `/CLAUDE.md`, `/.claude/`, `**/.gitignore`, and the CODEOWNERS file itself are owned by the release engineering team.

More specific rules must stay **below** the catch-all — GitHub applies the last matching rule, so re-ordering silently changes ownership.

## Things to leave alone unless asked

- `storage-layout.json`, `slither-baseline.json`, `script/gas/baselines.yml`, and `coverage.excludes.md` are **evidence, not knobs**. Regenerating or widening one to turn a red check green hides exactly the class of problem the check exists to catch. Change them only when the underlying change is intentional, and justify it in the PR.
- `ignored_error_codes` in `foundry.toml` — each entry has a comment explaining why it's a solc false positive or a test-only relaxation. Don't add codes to silence a real warning.
- `lib/` submodules — pinned commits. Bump the submodule and update the version table in `README.md`; never patch vendored source in place.
- The `evm_version = "osaka"` target and `bytecode_hash = "none"` / `cbor_metadata = false` settings are deliberate (Fusaka EVM target; initcode-size headroom). The Besu e2e genesis files (`test/e2e/backend/besu/genesis-a.json`, `genesis-b.json`) activate the matching forks at time 0 — changing one without the other breaks the Besu backend.
- Intentional spellings in upstream Hiero / Hedera / Besu path or repo names should not be "fixed" without confirming upstream first.
