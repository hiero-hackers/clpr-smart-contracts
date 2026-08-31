#!/usr/bin/env npx tsx
/**
 * Minimal Besu setup so submitBundle can run: deploy HieroVerifier (trustAnchor.bin),
 * register + complete a channel, register endpoint. Writes .channel.json.
 *
 * Prerequisites: forge build, ClprService deployed, Besu up (npm run e2e:up).
 */
import {privateKeyToAccount} from "viem/accounts";
import {parseEther, type Hex} from "viem";
import {makeClients} from "../e2e/lib/clients.js";
import type {DeployClients} from "../../script/deploy/client.js";
import {loadArtifact} from "../../script/deploy/artifacts.js";
import {deployHieroVerifierStack} from "../../script/deploy/deployWithHieroVerifier.js";
import {
    channelCommitment,
    connectorCommitment,
    deriveChannelId,
    deriveConnectorId,
    digestForChannelReveal,
    digestForConnectorReveal,
    uncompressedPubKey64
} from "../e2e/lib/ids.js";
import {wireConfig, registerEndpoint} from "../e2e/deploy/wire.js";
import {
    besuRpcA,
    besuRpcB,
    clprService,
    privateKey,
    trustAnchorHex,
    writeChannelRecord,
    type ChannelRecord
} from "./lib/config.js";
import {decodeChannelLeafFromProof} from "./lib/proof.js";
import {
    ChannelStatus,
    channelStatusLabel,
    readChannel
} from "./lib/channel.js";

const ZERO_BYTES32 = `0x${"00".repeat(32)}` as Hex;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Hex;

async function readLocalChainId(rpcUrl: string, service: Hex): Promise<string> {
    const clients = makeClients({rpcUrl, chainId: 1337, privateKey: privateKey()});
    const artifact = loadArtifact("ClprService");
    const raw = (await clients.publicClient.readContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "getLedgerConfiguration"
    })) as {chainId: string};
    return raw.chainId;
}

async function hasCode(rpcUrl: string, addr: Hex): Promise<boolean> {
    const clients = makeClients({rpcUrl, chainId: 1337, privateKey: privateKey()});
    const code = await clients.publicClient.getCode({address: addr});
    return !!code && code !== "0x";
}

async function hieroVerifierOnChain(
    clients: ReturnType<typeof makeClients>,
    verifierEnv?: Hex
): Promise<Hex> {
    if (verifierEnv) {
        console.log(`Using HieroVerifier=${verifierEnv}`);
        return verifierEnv;
    }
    const prev = process.env.HIERO_VERIFIER;
    delete process.env.HIERO_VERIFIER;
    try {
        const stack = await deployHieroVerifierStack(clients as DeployClients, trustAnchorHex());
        console.log(`Deployed HieroVerifier → ${stack.hieroVerifier} (ledgerId=trustAnchor.bin…)`);
        return stack.hieroVerifier;
    } finally {
        if (prev === undefined) delete process.env.HIERO_VERIFIER;
        else process.env.HIERO_VERIFIER = prev;
    }
}

/** peerChainId used in completeChannel's channelId check (empty when config proof is 0x). */
async function readPeerChainIdForChannelId(
    clients: ReturnType<typeof makeClients>,
    verifier: Hex,
    configProof: Hex
): Promise<string> {
    const artifact = loadArtifact("HieroVerifier");
    const [peerChainId] = (await clients.publicClient.readContract({
        address: verifier,
        abi: artifact.abi as never,
        functionName: "verifyConfig",
        args: [configProof]
    })) as [string];
    return peerChainId;
}

async function deriveChannelIdOnChain(
    clients: ReturnType<typeof makeClients>,
    service: Hex,
    peerChainId: string,
    pubKey: Hex,
    salt: Hex
): Promise<Hex> {
    const artifact = loadArtifact("ClprService");
    return (await clients.publicClient.readContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "deriveChannelId",
        args: [peerChainId, pubKey, salt]
    })) as Hex;
}

async function completeOnChain(
    clients: ReturnType<typeof makeClients>,
    service: Hex,
    args: {
        channelId: Hex;
        pubKey: Hex;
        sig: Hex;
        salt: Hex;
        verifier: Hex;
        configProof: Hex;
    }
): Promise<void> {
    const artifact = loadArtifact("ClprService");
    const tx = await clients.walletClient.writeContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "completeChannel",
        args: [args.channelId, args.pubKey, args.sig, args.salt, args.verifier, args.configProof, "0x"]
    });
    await clients.publicClient.waitForTransactionReceipt({hash: tx});
}

async function registerOnChain(
    clients: ReturnType<typeof makeClients>,
    service: Hex,
    channelId: Hex,
    commitment: Hex
): Promise<void> {
    const artifact = loadArtifact("ClprService");
    const tx = await clients.walletClient.writeContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "registerChannel",
        args: [channelId, commitment]
    });
    await clients.publicClient.waitForTransactionReceipt({hash: tx});
}

async function closeChannelOnChain(
    clients: ReturnType<typeof makeClients>,
    service: Hex,
    channelId: Hex
): Promise<void> {
    const artifact = loadArtifact("ClprService");
    const tx = await clients.walletClient.writeContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "closeChannel",
        args: [channelId]
    });
    await clients.publicClient.waitForTransactionReceipt({hash: tx});
    console.log(`\nClosed stale channel ${channelId.slice(0, 18)}…`);
}

/** Increment a bytes32 salt by 1 so we can rotate past a stale/broken channel. */
function nextSalt(salt: Hex): Hex {
    const n = (BigInt(salt) + 1n) & ((1n << 256n) - 1n);
    return `0x${n.toString(16).padStart(64, "0")}` as Hex;
}

async function deployMockConnector(clients: ReturnType<typeof makeClients>): Promise<Hex> {
    const existing = process.env.MOCK_CONNECTOR as Hex | undefined;
    if (existing) {
        console.log(`Using MOCK_CONNECTOR=${existing}`);
        return existing;
    }
    const artifact = loadArtifact("MockClprConnector");
    const hash = await clients.walletClient.deployContract({
        abi: artifact.abi as never,
        bytecode: artifact.bytecode,
        args: []
    });
    const receipt = await clients.publicClient.waitForTransactionReceipt({hash});
    const addr = receipt.contractAddress;
    if (!addr) throw new Error("MockClprConnector deploy returned no address");
    console.log(`Deployed MockClprConnector → ${addr}`);
    return addr;
}

async function setupConnector(
    clients: ReturnType<typeof makeClients>,
    service: Hex,
    channelId: Hex,
    connectorContract: Hex,
    operator: ReturnType<typeof privateKeyToAccount>,
    operatorPubKey: Hex,
    salt: Hex
): Promise<Hex> {
    const artifact = loadArtifact("ClprService");

    const connectorId = deriveConnectorId({channelId, pubKey: operatorPubKey, salt});
    const hasConnector = (await clients.publicClient.readContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "hasConnector",
        args: [channelId, connectorId]
    })) as boolean;

    if (hasConnector) {
        console.log(`\nConnector already registered (connectorId=${connectorId.slice(0, 18)}…). Skipping.`);
        return connectorId;
    }

    const commitment = connectorCommitment(connectorId, operatorPubKey);
    const regTx = await clients.walletClient.writeContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "registerConnector",
        args: [commitment]
    });
    await clients.publicClient.waitForTransactionReceipt({hash: regTx});

    const sig = await operator.signMessage({
        message: {raw: digestForConnectorReveal(connectorId, service)}
    });
    const completeTx = await clients.walletClient.writeContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "completeConnector",
        args: [connectorId, operatorPubKey, sig, salt, channelId, connectorContract, operator.address],
        value: parseEther("0.1")
    });
    await clients.publicClient.waitForTransactionReceipt({hash: completeTx});
    console.log(`\nRegistered connector (connectorId=${connectorId.slice(0, 18)}…, contract=${connectorContract})`);
    return connectorId;
}

async function sendOutboundMessage(
    clients: ReturnType<typeof makeClients>,
    service: Hex,
    channelId: Hex,
    connectorId: Hex
): Promise<void> {
    const artifact = loadArtifact("ClprService");
    const conn = await readChannel(clients.publicClient, service, channelId);
    // nextMessageId starts at 1 on a fresh channel; we need > 1 so the ack check passes.
    if (conn && conn.nextMessageId > 1n) {
        console.log(`\nChannel already has nextMessageId=${conn.nextMessageId} — skipping sendMessage.`);
        return;
    }

    const tx = await clients.walletClient.writeContract({
        address: service,
        abi: artifact.abi as never,
        functionName: "sendMessage",
        args: [channelId, connectorId, "0x", "0xdeadbeef"] // payload: "hello"
    });
    await clients.publicClient.waitForTransactionReceipt({hash: tx});
    console.log(`\nSent outbound message to advance nextMessageId.`);
}

async function printChannel(clients: ReturnType<typeof makeClients>, service: Hex, channelId: Hex) {
    const conn = await readChannel(clients.publicClient, service, channelId);
    if (!conn) {
        console.warn(`\nChannel ${channelId} not found on chain after establish.`);
        return;
    }
    console.log("\n── Channel on chain ──");
    console.log(JSON.stringify({
        channelId: conn.channelId,
        status: conn.status,
        verifier: conn.verifier,
        trustAnchor: conn.trustAnchor,
        peerChainId: conn.chainId,
        ackedMessageId: conn.ackedMessageId.toString(),
        receivedMessageId: conn.receivedMessageId.toString(),
        nextMessageId: conn.nextMessageId.toString()
    }, null, 2));
}

async function main(): Promise<void> {
    const configProof = "0x" as Hex;
    const service = clprService();
    const pk = privateKey();
    const trustAnchor = trustAnchorHex();

    const rpcA = besuRpcA();
    const wireBoth = process.env.WIRE_BOTH_CHAINS === "1";
    const chainIdA = Number(await makeClients({rpcUrl: rpcA, chainId: 1337, privateKey: pk}).publicClient.getChainId());
    const clientsA = makeClients({rpcUrl: rpcA, chainId: chainIdA, privateKey: pk});
    let clientsB: ReturnType<typeof makeClients> | undefined;
    if (wireBoth) {
        const rpcB = besuRpcB();
        const chainIdB = Number(await makeClients({rpcUrl: rpcB, chainId: 1338, privateKey: pk}).publicClient.getChainId());
        clientsB = makeClients({rpcUrl: rpcB, chainId: chainIdB, privateKey: pk});
    }

    if (!(await hasCode(rpcA, service))) {
        throw new Error(`No contract at CLPR_SERVICE=${service} on besu-a (${rpcA})`);
    }

    const localChainIdA = await readLocalChainId(rpcA, service);
    console.log(`RPC (${rpcA}) local chainId=${localChainIdA}`);
    console.log(`trustAnchor.bin (${(trustAnchor.length - 2) / 2} bytes): ${trustAnchor}`);
    const proofLeaf = decodeChannelLeafFromProof();
    if (proofLeaf) {
        console.log(`stateProof.json channel leaf (Hedera):`, proofLeaf);
    }

    await wireConfig({clients: clientsA, addrs: {clprService: service}});

    const operatorKey = (process.env.OPERATOR_PRIVATE_KEY as Hex | undefined) ?? privateKey();
    const operator = privateKeyToAccount(operatorKey);
    const operatorPubKey = uncompressedPubKey64(operator.publicKey);

    const verifier = await hieroVerifierOnChain(clientsA, process.env.HIERO_VERIFIER as Hex | undefined);
    const peerChainId = await readPeerChainIdForChannelId(clientsA, verifier, configProof);

    // ── Find a usable salt (rotate past any stale/broken channels) ──────────
    // A broken channel is one whose peerThrottles.maxMessagePayloadBytes == 0;
    // this happens when the channel was established with an old HieroVerifier
    // whose verifyConfig returned zeroed throttles.  closeChannel() marks the
    // slot CLOSING (unreusable), so we increment the salt until we find a slot
    // with no existing channel.
    let salt = (process.env.CHANNEL_SALT as Hex | undefined) ?? ZERO_BYTES32;
    let channelId: Hex;
    // eslint-disable-next-line no-constant-condition
    while (true) {
        const idFromTs = deriveChannelId({localChainId: localChainIdA, peerChainId, pubKey: operatorPubKey, salt});
        const idOnChain = await deriveChannelIdOnChain(clientsA, service, peerChainId, operatorPubKey, salt);
        if (idFromTs !== idOnChain) {
            throw new Error(`channelId mismatch: TS ${idFromTs} vs on-chain ${idOnChain}`);
        }
        channelId = idOnChain;

        const existing = await readChannel(clientsA.publicClient, service, channelId);
        if (!existing || existing.verifier === ZERO_ADDRESS) {
            // Fresh slot — use this one
            break;
        }

        const throttleOk = (existing.peerThrottles?.maxMessagePayloadBytes ?? 0n) > 0n;
        // A channel is reusable only if it is ACTIVE, has valid throttles, AND has never
        // received a bundle yet (receivedMessageId === 0).  If receivedMessageId > 0 the
        // stateProof.bin fixture was already submitted against this slot and a second
        // submitBundle would revert with ClprReplayDetected.  Rotate to a fresh slot.
        const proofFresh = existing.receivedMessageId === 0n;
        if (throttleOk && existing.status === ChannelStatus.ACTIVE && proofFresh) {
            // Fully healthy channel, proof not yet submitted — reuse it
            break;
        }

        // Broken, used-up, or CLOSING channel — close it (noop if already CLOSING) and rotate salt
        if (existing.status === ChannelStatus.ACTIVE) {
            if (!throttleOk) {
                console.warn(
                    `\nChannel ${channelId.slice(0, 18)}… has zeroed peerThrottles ` +
                        `(established with stale verifier). Closing and rotating salt…`
                );
            } else {
                console.warn(
                    `\nChannel ${channelId.slice(0, 18)}… proof already submitted ` +
                        `(receivedMessageId=${existing.receivedMessageId}). Closing and rotating salt…`
                );
            }
            try {
                await closeChannelOnChain(clientsA, service, channelId);
            } catch {
                // Already CLOSING or some other terminal state
            }
        } else {
            console.warn(
                `\nChannel ${channelId.slice(0, 18)}… status=${channelStatusLabel(existing.status)} — rotating salt…`
            );
        }
        salt = nextSalt(salt);
    }

    console.log(`\nBesu channelId=${channelId!}`);
    console.log(`operator=${operator.address} pubKey64=${operatorPubKey.slice(0, 18)}…`);
    if (salt !== ZERO_BYTES32) {
        console.log(`Using rotated salt=${salt} (original slot was stale)`);
    }

    const commitment = channelCommitment(channelId!, operatorPubKey);
    const existing = await readChannel(clientsA.publicClient, service, channelId!);

    const channelEstablished =
        existing !== null &&
        existing.verifier !== ZERO_ADDRESS &&
        existing.verifier !== undefined &&
        (existing.peerThrottles?.maxMessagePayloadBytes ?? 0n) > 0n;

    if (channelEstablished) {
        console.log(
            `\nChannel already on-chain (status=${channelStatusLabel(existing!.status)}, ` +
                `verifier=${existing!.verifier}). Skipping register/complete.`
        );
        if (existing!.status !== ChannelStatus.ACTIVE) {
            console.warn(
                `Warning: proof path expects ACTIVE (1); reset Besu to re-establish.`
            );
        }
    } else {
        console.log(`\nNo channel on-chain yet — registering and completing.`);
        await registerOnChain(clientsA, service, channelId!, commitment);
        const sigA = await operator.signMessage({
            message: {raw: digestForChannelReveal(channelId!, service)}
        });
        await completeOnChain(clientsA, service, {
            channelId: channelId!, pubKey: operatorPubKey, sig: sigA, salt, verifier, configProof
        });
    }

    const onChainVerifier = channelEstablished && existing ? existing.verifier : verifier;

    if (wireBoth && clientsB && (await hasCode(besuRpcB(), service))) {
        const rpcB = besuRpcB();
        await readLocalChainId(rpcB, service);
        await wireConfig({clients: clientsB, addrs: {clprService: service}});
        const existingB = await readChannel(clientsB.publicClient, service, channelId);
        if (existingB && existingB.verifier !== ZERO_ADDRESS) {
            console.log(`\nChannel already on besu-b (${rpcB}) — skipped second chain wire.`);
        } else {
            const verifierB = await hieroVerifierOnChain(
                clientsB,
                process.env.HIERO_VERIFIER_B as Hex | undefined
            );
            const peerChainIdB = await readPeerChainIdForChannelId(clientsB, verifierB, configProof);
            const idFromB = await deriveChannelIdOnChain(
                clientsB, service, peerChainIdB, operatorPubKey, salt
            );
            if (idFromB !== channelId) {
                throw new Error(
                    `channelId mismatch on besu-b: ${idFromB} vs ${channelId}. ` +
                        `With empty CONFIG_PROOF, peerChainId is often "" on both chains — ` +
                        `local ledger chainId must match on A and B for the same channelId.`
                );
            }
            await registerOnChain(clientsB, service, channelId, commitment);
            const sigB = await operator.signMessage({
                message: {raw: digestForChannelReveal(channelId, service)}
            });
            await completeOnChain(clientsB, service, {
                channelId, pubKey: operatorPubKey, sig: sigB, salt, verifier: verifierB, configProof
            });
            console.log(`\nAlso wired channel on besu-b (${rpcB})`);
        }
    } else if (wireBoth) {
        console.warn(`\nWIRE_BOTH_CHAINS=1 but no ClprService code on besu-b — skipped second chain`);
    }

    const existingEntry = (await clientsA.publicClient.readContract({
        address: service,
        abi: loadArtifact("ClprService").abi as never,
        functionName: "getEndpointEntry",
        args: [clientsA.account.address]
    })) as {status: number};
    if (existingEntry.status === 0) {
        // EndpointStatus.NONE — no entry yet; self-register as a PENDING endpoint.
        await registerEndpoint({
            clients: clientsA,
            clprService: service,
            bond: parseEther("0.1")
        });
        console.log(`\nRegistered endpoint ${clientsA.account.address}`);
    }

    // Deploy a connector + send one outbound message so conn.nextMessageId > 0.
    // submitBundle requires metadata.receivedMessageId < conn.nextMessageId (ack check).
    const mockConnector = await deployMockConnector(clientsA);
    const connectorId = await setupConnector(
        clientsA, service, channelId, mockConnector, operator, operatorPubKey, salt
    );
    await sendOutboundMessage(clientsA, service, channelId, connectorId);

    await printChannel(clientsA, service, channelId);

    const record: ChannelRecord = {
        channelId,
        operatorPrivateKey: operatorKey,
        operatorPubKey,
        operatorAddress: operator.address,
        salt,
        hieroVerifier: onChainVerifier,
        localChainId: localChainIdA,
        peerChainId,
        clprService: service,
        createdAt: new Date().toISOString()
    };
    writeChannelRecord(record);
    console.log(`\nWrote verification-inputs/.channel.json`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
