import {readFile} from "node:fs/promises";
import {createPublicClient, createWalletClient, http, parseEther} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {chainIdFor, deploymentFor, type SoloSide} from "./config.ts";
import {parseEcdsaAliasKey, soloAccountsPath} from "./artifacts.ts";
import {resolveRelayUrl} from "./state.ts";

const MIN_BALANCE = parseEther("50");
const FUND_AMOUNT = parseEther("1000");
const FUND_TX_MAX_ATTEMPTS = 12;
const FUND_TX_RETRY_BASE_MS = 1_000;

const sideFundLocks = new Map<SoloSide, Promise<void>>();

function isNonceTooLow(err: unknown): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    return /nonce too low/i.test(msg);
}

function isTransientRelayError(err: unknown): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    return /internal server error|missing or invalid parameters|simulation|timeout|temporarily unavailable|not found/i.test(
        msg
    );
}

/// Solo relays often answer eth_chainId before mirror/consensus accept eth_estimateGas.
export async function waitForSoloRelayTransfers(side: SoloSide, timeoutMs = 180_000): Promise<void> {
    const rpc = await requireRelayUrl(side);
    const chainId = chainIdFor(side);
    const funderKey = await loadSideKey(side);
    const funder = privateKeyToAccount(funderKey);
    const publicClient = createPublicClient({transport: http(rpc)});
    const deadline = Date.now() + timeoutMs;
    let lastErr: unknown;

    while (Date.now() < deadline) {
        try {
            const bal = await publicClient.getBalance({address: funder.address});
            if (bal === 0n) throw new Error(`funder ${funder.address} balance is 0`);
            await publicClient.estimateGas({
                account: funder.address,
                to: funder.address,
                value: 1n
            });
            return;
        } catch (err) {
            lastErr = err;
            await new Promise((r) => setTimeout(r, 2_000));
        }
    }

    throw new Error(
        `Solo relay side ${side} not ready for transfers after ${timeoutMs / 1000}s: ${String(lastErr)}`
    );
}

/// Wait until Mirror Node web3's contracts/call path is ready AND stable.
/// The relay routes eth_estimateGas with non-empty calldata to Mirror Node web3 for EVM
/// simulation (different service from mirror-1-rest, which is already probed by the port-forward).
/// We send a dummy 4-byte selector — it will revert, but a revert means web3 is up and
/// processing requests. Retry on transient 500-class responses (Mirror Node not ready yet).
/// Requires PROBE_REQUIRED consecutive successful responses to guard against flapping: Mirror Node
/// can briefly respond during start-up and then return 500 again as it initialises its database.
///
/// Note: this probe uses publicClient.estimateGas (no EIP-1559 fee params, no nonce, to = known
/// address). Mirror Node also rejects eth_estimateGas with EIP-1559 params when the recipient
/// does not yet exist on Hedera (new accounts are created lazily; the simulation can't do that).
/// fundAccountOnSoloSide avoids that by specifying gas: 21_000n explicitly.
export async function waitForSoloMirrorContractSim(side: SoloSide, timeoutMs = 180_000): Promise<void> {
    const PROBE_REQUIRED = 3; // consecutive non-transient responses needed
    const PROBE_INTERVAL_MS = 2_000;

    const rpc = await requireRelayUrl(side);
    const funderKey = await loadSideKey(side);
    const funder = privateKeyToAccount(funderKey);
    const publicClient = createPublicClient({transport: http(rpc)});
    const deadline = Date.now() + timeoutMs;
    let lastErr: unknown;
    let consecutive = 0;

    while (Date.now() < deadline) {
        try {
            await publicClient.estimateGas({
                account: funder.address,
                to: funder.address,
                data: "0x00000000",
                value: 0n
            });
            consecutive++;
        } catch (err) {
            if (!isTransientRelayError(err)) {
                consecutive++; // revert / bad-input = web3 processed the request
            } else {
                consecutive = 0; // 500-class = Mirror Node not ready, reset streak
                lastErr = err;
            }
        }
        if (consecutive >= PROBE_REQUIRED) return;
        await new Promise((r) => setTimeout(r, PROBE_INTERVAL_MS));
    }

    throw new Error(
        `Solo Mirror Node web3 (contracts/call) side ${side} not ready after ${timeoutMs / 1000}s: ${String(lastErr)}`
    );
}

/** Serialize funding per Solo side — all suites share the same ecdsa-alias funder per relay. */
async function withSideFundLock<T>(side: SoloSide, fn: () => Promise<T>): Promise<T> {
    const prev = sideFundLocks.get(side) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
        release = resolve;
    });
    sideFundLocks.set(side, prev.then(() => gate));
    await prev;
    try {
        return await fn();
    } finally {
        release();
    }
}

/// Fund a suite-specific address on both Solo relays (each side's ecdsa-alias pays).
export async function fundAccountOnSolo(recipient: `0x${string}`, _label: string): Promise<void> {
    for (const side of ["a", "b"] as const) {
        await withSideFundLock(side, async () => fundAccountOnSoloSide(side, recipient));
    }
}

/// Fund a suite-specific address on a single Solo relay side.
export async function fundSoloSide(side: SoloSide, recipient: `0x${string}`): Promise<void> {
    await withSideFundLock(side, async () => fundAccountOnSoloSide(side, recipient));
}

async function fundAccountOnSoloSide(side: SoloSide, recipient: `0x${string}`): Promise<void> {
    const rpc = await requireRelayUrl(side);
    const chainId = chainIdFor(side);
    const funderKey = await loadSideKey(side);
    const funder = privateKeyToAccount(funderKey);
    const publicClient = createPublicClient({transport: http(rpc)});
    const bal = await publicClient.getBalance({address: recipient});
    if (bal >= MIN_BALANCE) return;

    const wallet = createWalletClient({
        account: funder,
        transport: http(rpc),
        chain: {
            id: chainId,
            name: `solo-${side}`,
            nativeCurrency: {name: "HBAR", symbol: "HBAR", decimals: 18},
            rpcUrls: {default: {http: [rpc]}}
        }
    });

    await waitForSoloRelayTransfers(side);

    for (let attempt = 1; attempt <= FUND_TX_MAX_ATTEMPTS; attempt++) {
        try {
            // Mirror Node's contracts/call endpoint cannot simulate EIP-1559 value
            // transfers to accounts that don't yet exist on Hedera (Hedera creates
            // accounts lazily on first receive, but eth_estimateGas is a dry-run that
            // can't trigger that side effect). A plain value transfer always costs the
            // EVM-protocol-constant 21 000 gas regardless of chain, so skipping
            // estimation here is semantically correct, not a workaround.
            const hash = await wallet.sendTransaction({to: recipient, value: FUND_AMOUNT, gas: 21_000n});
            await publicClient.waitForTransactionReceipt({hash, timeout: 300_000});
            return;
        } catch (err) {
            const retryable = isNonceTooLow(err) || isTransientRelayError(err);
            if (!retryable || attempt === FUND_TX_MAX_ATTEMPTS) throw err;
            await new Promise((r) => setTimeout(r, FUND_TX_RETRY_BASE_MS * attempt));
        }
    }
}

export async function loadSoloFunderKey(side: SoloSide = "a"): Promise<`0x${string}`> {
    return loadSideKey(side);
}

async function loadSideKey(side: SoloSide): Promise<`0x${string}`> {
    const path = soloAccountsPath(deploymentFor(side));
    const raw = await readFile(path, "utf8");
    return parseEcdsaAliasKey(path, raw);
}

async function requireRelayUrl(side: SoloSide): Promise<string> {
    const url = (await resolveRelayUrl(side)) ?? process.env[side === "a" ? "SOLO_RPC_A" : "SOLO_RPC_B"];
    if (!url) throw new Error(`relay URL for side ${side} missing — run npm run e2e:solo:up`);
    return url;
}
