import {createPublicClient, http, parseEther} from "viem";
import {chainIdFor} from "./config.js";
import {applySoloRpcEnv, resolveRelayUrl} from "./state.js";
import {parseBackendSpec} from "../Backend.js";
import type {ChainClients} from "../../lib/clients.js";
import type {SoloSide} from "./config.js";

/// Which sides (if any) are configured as Solo in the current CLPR_BACKEND spec.
export function soloSides(): SoloSide[] {
    const {kindA, kindB} = parseBackendSpec();
    const sides: SoloSide[] = [];
    if (kindA === "solo") sides.push("a");
    if (kindB === "solo") sides.push("b");
    return sides;
}

/// True if either chain A or chain B is backed by Solo.
export function isSoloBackend(): boolean {
    return soloSides().length > 0;
}

/// True only when both sides are Solo (affects nonce alignment, deploy parallelism, etc.).
export function isBothSideSolo(): boolean {
    return soloSides().length === 2;
}

/// Vitest globalSetup: verify relays before any Solo spec runs.
export default async function soloE2EGlobalSetup(): Promise<void> {
    const sides = soloSides();
    if (sides.length === 0) return;
    await ensureSoloE2ERelays(sides);
}

/// Apply relay URLs from `.solo-state` and confirm chain IDs for the given sides.
export async function ensureSoloE2ERelays(sides: SoloSide[]): Promise<void> {
    if (sides.length === 0) return;
    await applySoloRpcEnv();

    for (const side of sides) {
        const rpc = await resolveRelayUrl(side);
        if (!rpc) {
            throw new Error(`Solo not running for side ${side}. Run: npm run e2e:solo:up`);
        }
        const id = await createPublicClient({transport: http(rpc)}).getChainId();
        if (Number(id) !== chainIdFor(side)) {
            throw new Error(`side ${side}: chainId ${id}, expected ${chainIdFor(side)}`);
        }
    }

    await applySoloRpcEnv();
}

/// Kept for backward compatibility — delegates to ensureSoloE2ERelays(["a","b"]).
export async function ensureSoloE2ERelaysReady(): Promise<void> {
    await ensureSoloE2ERelays(["a", "b"]);
}

/// Payable ClprService ops use delegatecall; the relay does not forward tx.value.
export function soloClprValue(amount: bigint): bigint {
    return isSoloBackend() ? 0n : amount;
}

/// Hedera gas price is ~710 gwei; 5M gas headroom needs several ETH. 300k is enough for e2e apps.
export const SOLO_MAX_GAS_PER_MESSAGE = 300_000n;

/// Match pending nonces on A/B before forge so CREATE2 deploy addresses align across relays.
/// Only needed when both sides are Solo (they share the same deployer key via a single ecdsa-alias).
export async function alignSoloDeployerNonces(a: ChainClients, b: ChainClients): Promise<void> {
    if (!isBothSideSolo()) return;

    const [balA, balB] = await Promise.all([
        a.publicClient.getBalance({address: a.account.address}),
        b.publicClient.getBalance({address: b.account.address})
    ]);
    if (balA === 0n && balB === 0n) return;

    const [nA, nB] = await Promise.all([pendingNonce(a), pendingNonce(b)]);
    const target = Math.max(nA, nB);
    await bumpNonceTo(a, target);
    await bumpNonceTo(b, target);
}

async function pendingNonce(clients: ChainClients): Promise<number> {
    return clients.publicClient.getTransactionCount({
        address: clients.account.address,
        blockTag: "pending"
    });
}

async function bumpNonceTo(clients: ChainClients, target: number): Promise<void> {
    const address = clients.account.address;
    if ((await clients.publicClient.getBalance({address})) === 0n) return;

    let current = await pendingNonce(clients);
    while (current < target) {
        const hash = await clients.walletClient.sendTransaction({to: address, value: 0n});
        await clients.publicClient.waitForTransactionReceipt({hash});
        current = await pendingNonce(clients);
    }
}

/// Minimum MockClprConnector balance for BundleLib's pre-dispatch underfunded check.
export async function soloMinConnectorFund(
    publicClient: {getGasPrice: () => Promise<bigint>},
    maxGasPerMessage: bigint = SOLO_MAX_GAS_PER_MESSAGE,
    endpointMarginPercent: bigint = 10n
): Promise<bigint> {
    const gasPrice = await publicClient.getGasPrice();
    const required = (maxGasPerMessage * gasPrice * (100n + endpointMarginPercent)) / 100n;
    const floor = parseEther("1");
    const withHeadroom = required + required / 10n;
    return withHeadroom > floor ? withHeadroom : floor;
}
