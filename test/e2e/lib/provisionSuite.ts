import {createPublicClient, createWalletClient, http, keccak256, parseEther, toBytes} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import type {Backend} from "../backend/Backend.js";
import {fundSoloSide} from "../backend/solo/fund.js";
import {makeClients, type ChainClients} from "./clients.js";
import {alignSoloDeployerNonces, isBothSideSolo} from "../backend/solo/solo.js";

const MIN_BALANCE = parseEther("50");
const FUND_AMOUNT = parseEther("1000");

export interface ProvisionedSuite {
    suiteId: string;
    privateKey: `0x${string}`;
    address: `0x${string}`;
    clientsA: ChainClients;
    clientsB: ChainClients;
}

/// Deterministic private key per Vitest suite so runs are isolated but reproducible.
export function suitePrivateKey(suiteId: string): `0x${string}` {
    return keccak256(toBytes(`testing-suite:v1:${suiteId}`));
}

/// Create a suite-only account, fund it on A and B, and return chain clients.
/// Funding is done per-side: Solo sides use the ecdsa-alias funder, dev chains use fundedKeyA/B.
export async function provisionE2ESuite(backend: Backend, suiteId: string): Promise<ProvisionedSuite> {
    const privateKey = suitePrivateKey(suiteId);
    const address = privateKeyToAccount(privateKey).address;

    await Promise.all([
        fundSide("a", backend, address),
        fundSide("b", backend, address)
    ]);

    const clientsA = makeClients({rpcUrl: backend.rpcA(), chainId: 1337, privateKey, soloRelay: backend.kindA() === "solo"});
    const clientsB = makeClients({rpcUrl: backend.rpcB(), chainId: 1338, privateKey, soloRelay: backend.kindB() === "solo"});

    if (isBothSideSolo()) {
        await alignSoloDeployerNonces(clientsA, clientsB);
    }

    return {suiteId, privateKey, address, clientsA, clientsB};
}

async function fundSide(
    side: "a" | "b",
    backend: Backend,
    recipient: `0x${string}`
): Promise<void> {
    const kind = side === "a" ? backend.kindA() : backend.kindB();
    if (kind === "solo") {
        await fundSoloSide(side, recipient);
        return;
    }
    const rpcUrl = side === "a" ? backend.rpcA() : backend.rpcB();
    const chainId = side === "a" ? 1337 : 1338;

    // Avalanche uses the ewoq account (pre-funded test account) for funding
    if (kind === "avalanche") {
        const EWOQ_KEY = "0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027";
        await fundOnDevChain(rpcUrl, chainId, EWOQ_KEY, recipient);
        return;
    }

    const funderKey = side === "a" ? backend.fundedKeyA() : backend.fundedKeyB();
    await fundOnDevChain(rpcUrl, chainId, funderKey, recipient);
}

async function fundOnDevChain(
    rpcUrl: string,
    chainId: number,
    funderKey: `0x${string}`,
    recipient: `0x${string}`
): Promise<void> {
    const chain = {
        id: chainId,
        name: `dev-${chainId}`,
        nativeCurrency: {name: "ETH", symbol: "ETH", decimals: 18},
        rpcUrls: {default: {http: [rpcUrl]}}
    };
    const account = privateKeyToAccount(funderKey);
    const publicClient = createPublicClient({transport: http(rpcUrl)});
    const bal = await publicClient.getBalance({address: recipient});
    if (bal >= MIN_BALANCE) return;

    const wallet = createWalletClient({account, transport: http(rpcUrl), chain});
    const hash = await wallet.sendTransaction({to: recipient, value: FUND_AMOUNT});
    await publicClient.waitForTransactionReceipt({hash});
}
