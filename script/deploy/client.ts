import {createPublicClient, createWalletClient, http, type Chain} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {createNonceManager, jsonRpc} from "viem/nonce";

export interface DeployClients {
    chain: Chain;
    account: ReturnType<typeof privateKeyToAccount>;
    publicClient: ReturnType<typeof createPublicClient>;
    walletClient: ReturnType<typeof createWalletClient>;
}

/// Local account with coordinated nonces for parallel contract deploys.
export function makeDeployAccount(privateKey: `0x${string}`) {
    const nonceManager = createNonceManager({source: jsonRpc()});
    return privateKeyToAccount(privateKey, {nonceManager});
}

export async function makeDeployClients(opts: {
    rpcUrl: string;
    privateKey: `0x${string}`;
}): Promise<DeployClients> {
    const account = makeDeployAccount(opts.privateKey);
    const transport = http(opts.rpcUrl);
    const publicClient = createPublicClient({transport});
    const id = Number(await publicClient.getChainId());
    const chain: Chain = {
        id,
        name: `clpr-${id}`,
        nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
        rpcUrls: {default: {http: [opts.rpcUrl]}}
    };
    const walletClient = createWalletClient({account, chain, transport});
    return {chain, account, publicClient, walletClient};
}
