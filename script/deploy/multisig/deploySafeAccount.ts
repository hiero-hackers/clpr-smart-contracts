import {loadArtifact} from "../artifacts.js";
import type {DeployClients} from "../client.js";
import {decodeEventLog, encodeFunctionData, getAddress} from "viem";
import {SafeAccountDeployment, SafeDeployment, SafeFullDeployment, SafeSetupParams} from "./safeConfig.js";
import {deployArtifact} from "../deployCore.js";

const ZERO_ADDRESS: `0x${string}` = "0x0000000000000000000000000000000000000000";

export async function deploySafeSingleton(
    clients: DeployClients
): Promise<`0x${string}`> {
    return await deployArtifact(clients, "Safe");
}

export async function deploySafeProxyFactory(
    clients: DeployClients,
): Promise<`0x${string}`> {
    return await deployArtifact(clients, "SafeProxyFactory");
}

export async function deploySafeAccount(
    clients: DeployClients,
    singleton: `0x${string}`,
    proxyFactory: `0x${string}`,
    params: SafeSetupParams
): Promise<SafeAccountDeployment> {

    const safeArtifact = loadArtifact("Safe");
    const proxyFactoryArtifact = loadArtifact("SafeProxyFactory");

    const initializer = encodeFunctionData({
        abi: safeArtifact.abi,
        functionName: "setup",
        args: [
            params.owners,
            params.threshold,
            params.to || ZERO_ADDRESS,
            params.data || "0x",
            params.fallbackHandler || ZERO_ADDRESS,
            params.paymentToken || ZERO_ADDRESS,
            params.payment ?? 0n,
            params.paymentReceiver || ZERO_ADDRESS
        ]
    });

    const saltNonce = params.saltNonce ?? 0n;

    const hash = await clients.walletClient.writeContract({
        address: proxyFactory,
        abi: proxyFactoryArtifact.abi,
        functionName: "createProxyWithNonce",
        chain: clients.chain,
        account: clients.account,
        args: [singleton, initializer, saltNonce]
    });

    const receipt = await clients.publicClient.waitForTransactionReceipt({ hash });

    // ProxyCreation(SafeProxy indexed proxy, address singleton) is emitted by the factory.
    const proxyCreationLog = receipt.logs.find(
        (log) => log.address.toLowerCase() === proxyFactory.toLowerCase()
    );

    if (!proxyCreationLog) {
        throw new Error("ProxyCreation event not found in transaction receipt");
    }

    const {args} = decodeEventLog({
        abi: proxyFactoryArtifact.abi as never,
        eventName: "ProxyCreation",
        topics: proxyCreationLog.topics,
        data: proxyCreationLog.data
    });

    const safe = getAddress((args as unknown as {proxy: `0x${string}`}).proxy);

    // Confirm the resolved address is a SafeProxy (fixed runtime bytecode) before it
    // can be handed ClprService ownership — guards against transferring to the wrong,
    // possibly unrecoverable, contract.
    const {deployedBytecode: expectedProxyRuntime} = loadArtifact("SafeProxy");
    const onChainRuntime = await clients.publicClient.getCode({address: safe});
    if (onChainRuntime?.toLowerCase() !== expectedProxyRuntime.toLowerCase()) {
        throw new Error(
            `Deployed Safe account ${safe} does not have the expected SafeProxy bytecode. ` +
            `Refusing to proceed — transferring ownership to this address could be unrecoverable.`
        );
    }

    return {
        account: safe
    }
}

export async function deploySafeFull(
    clients: DeployClients,
    params: SafeSetupParams
): Promise<SafeFullDeployment> {
    const singleton = await deploySafeSingleton(clients);
    const factory = await deploySafeProxyFactory(clients);
    const account = await deploySafeAccount(clients, singleton, factory, params);
    return { singleton, factory, ...account };
}

export async function assertSafeDeployment(clients: DeployClients, modules: SafeDeployment): Promise<void> {
    const entries: [string, `0x${string}`][] = [
        ["SAFE_SINGLETON", modules.singleton],
        ["SAFE_FACTORY", modules.factory],
    ];
    const missing: string[] = [];
    for (const [name, addr] of entries) {
        const code = await clients.publicClient.getCode({address: addr});
        if (!code || code === "0x") missing.push(`${name}=${addr}`);
    }
    if (missing.length > 0) {
        throw new Error(
            `module addresses have no bytecode on this RPC:\n  - ${missing.join("\n  - ")}\nDeploy modules first.`
        );
    }
}