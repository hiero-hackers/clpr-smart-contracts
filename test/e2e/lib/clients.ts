import {
    createPublicClient,
    createWalletClient,
    encodeFunctionData,
    http,
    type Chain,
    type WriteContractParameters
} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {makeDeployAccount} from "../../../script/deploy/client.js";

/// Build viem public + wallet clients for a given chain (chainId set via `Chain` object).
/// The same funded key works on both Anvil and Besu (genesis prefunds it on Besu).
/// Pass `soloRelay: true` when the RPC endpoint is a Hiero JSON-RPC relay — enables
/// the payable-write wrapper that adds explicit gas for delegatecall targets.
export function makeClients(opts: {
    rpcUrl: string;
    chainId: number;
    privateKey: `0x${string}`;
    soloRelay?: boolean;
}) {
    const chain = {
        id: opts.chainId,
        name: `clpr-${opts.chainId}`,
        nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
        rpcUrls: {default: {http: [opts.rpcUrl]}}
    } satisfies Chain;

    const account = makeDeployAccount(opts.privateKey);
    const transport = http(opts.rpcUrl);

    // viem's default pollingInterval is 4000ms for HTTP transports — fine for
    // mainnet/L1 cadences but a 4× tax on each `waitForTransactionReceipt`
    // against fast local chains (Anvil: 50ms blocks; Besu QBFT: 1s blocks).
    // 250ms is well below both block times and keeps RPC pressure modest.
    const pollingInterval = 250;

    const publicClient = createPublicClient({chain, transport, pollingInterval});
    const baseWallet = createWalletClient({account, chain, transport, pollingInterval});
    const useSoloRelay = opts.soloRelay ?? process.env.CLPR_BACKEND === "solo";

    // Hedera/Solo transactions can take up to several minutes to finalize.
    // Patch waitForTransactionReceipt to use a 5-minute timeout instead of
    // viem's 180s default so contract deployments and setup calls don't expire.
    const effectivePublicClient = useSoloRelay
        ? withSoloReceiptTimeout(publicClient, 300_000)
        : publicClient;

    const walletClient = useSoloRelay
        ? withSoloPayableWrites(baseWallet, effectivePublicClient, account)
        : baseWallet;

    return {chain, account, publicClient: effectivePublicClient, walletClient};
}

/// Extend a publicClient so all waitForTransactionReceipt calls use at least `timeoutMs`.
/// Hedera/Solo transactions can take several minutes to finalize — viem's 180s default is too short.
function withSoloReceiptTimeout<T extends ReturnType<typeof createPublicClient>>(
    client: T,
    timeoutMs: number
): T {
    const orig = client.waitForTransactionReceipt.bind(client);
    const patched = (args: Parameters<typeof orig>[0]) =>
        orig({...args, timeout: timeoutMs} as Parameters<typeof orig>[0]);
    return Object.assign(client, {waitForTransactionReceipt: patched}) as T;
}

/// Hiero JSON-RPC relay can omit `value` in eth_estimateGas; payable calls need explicit gas.
/// Relay also does not surface `msg.value` inside delegatecall targets — e2e uses `minEndpointBond: 0` on Solo.
function withSoloPayableWrites<T extends ReturnType<typeof createWalletClient>>(
    wallet: T,
    publicClient: ReturnType<typeof createPublicClient>,
    account: ReturnType<typeof privateKeyToAccount>
): T {
    const orig = wallet.writeContract.bind(wallet);
    const patched = async (params: WriteContractParameters) => {
        const value = "value" in params ? params.value : undefined;
        if (!value || value === 0n) return orig(params);
        const data = encodeFunctionData({
            abi: params.abi,
            functionName: params.functionName,
            args: params.args
        });
        const hash = await wallet.sendTransaction({
            account,
            chain: wallet.chain,
            to: params.address,
            data,
            value,
            gas: 2_000_000n
        });
        const receipt = await publicClient.waitForTransactionReceipt({hash});
        if (receipt.status === "reverted") {
            throw new Error(
                `payable writeContract reverted: ${String(params.functionName)} → ${params.address}`
            );
        }
        return hash;
    };
    return Object.assign(wallet, {writeContract: patched}) as T;
}

export type ChainClients = ReturnType<typeof makeClients>;
