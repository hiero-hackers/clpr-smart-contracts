#!/usr/bin/env npx tsx
/**
 * Submit stateProof.bin via ClprService.submitBundle (proof path only).
 *
 * Prerequisites: npm run verify:establish-channel, forge build.
 *
 * Env: SUBMIT_RPC (default BESU_RPC_A), DRY_RUN=1, CHANNEL_ID override.
 */
import {toHex, type Hex} from "viem";
import {makeClients} from "../e2e/lib/clients.js";
import {loadArtifact} from "../../script/deploy/artifacts.js";
import {
    besuRpcA,
    clprService,
    privateKey,
    readChannelRecord,
    stateProofBytes,
    trustAnchorHex
} from "./lib/config.js";
import {decodeChannelLeafFromProof} from "./lib/proof.js";
import {ChannelStatus, channelStatusLabel, readChannel} from "./lib/channel.js";

/** ClprReplayDetected selector — thrown when the same proof is submitted twice. */
const CLPR_REPLAY_DETECTED = "0x24315cae";

function isReplayDetected(err: unknown): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    return msg.includes("24315cae") || msg.includes(CLPR_REPLAY_DETECTED.slice(2));
}

/** Throw a human-readable error when replay is detected. */
function throwReplayError(): never {
    throw new Error(
        `ClprReplayDetected: this proof was already submitted against the current channel.\n` +
        `Re-run  npm run verify:establish-channel  to rotate to a fresh channel slot, then retry.`
    );
}

async function main(): Promise<void> {
    const proof = stateProofBytes();
    const proofHex = toHex(proof) as Hex;
    const record = readChannelRecord();
    const channelId = (process.env.CHANNEL_ID as Hex | undefined) ?? record.channelId;
    const service = clprService();
    const rpc = process.env.SUBMIT_RPC ?? besuRpcA();
    const pk = privateKey();
    const chainId = Number(await makeClients({rpcUrl: rpc, chainId: 1337, privateKey: pk}).publicClient.getChainId());
    const clients = makeClients({rpcUrl: rpc, chainId, privateKey: pk});

    const serviceArtifact = loadArtifact("ClprService");
    const verifierArtifact = loadArtifact("HieroVerifier");

    console.log(`RPC: ${rpc} (chainId ${chainId})`);
    console.log(`proof: verification-inputs/stateProof.bin (${proof.length} bytes)`);
    console.log(`ClprService: ${service}`);
    console.log(`channelId: ${channelId}`);
    console.log(`trustAnchor.bin: ${trustAnchorHex()}`);

    const proofLeaf = decodeChannelLeafFromProof();
    if (proofLeaf) {
        console.log(`stateProof.json channel leaf:`, proofLeaf);
        console.log(
            `Note: Besu channelId (${channelId}) is EVM-derived; Hedera leaf id is ${proofLeaf.hederaChannelId}.`
        );
    }

    const conn = await readChannel(clients.publicClient, service, channelId);
    if (!conn) {
        throw new Error(
            `Channel ${channelId} not found on ${rpc}. Run npm run verify:establish-channel first.`
        );
    }

    if (conn.status !== ChannelStatus.ACTIVE) {
        throw new Error(
            `Channel status ${channelStatusLabel(conn.status)} (${conn.status}) — expected ACTIVE (1). ` +
                `Re-run establish-channel or reset Besu state.`
        );
    }
    console.log(`\nChannel before submit:`, {
        status: conn.status,
        verifier: conn.verifier,
        trustAnchor: conn.trustAnchor,
        receivedMessageId: conn.receivedMessageId.toString(),
        nextMessageId: conn.nextMessageId.toString(),
        ackedMessageId: conn.ackedMessageId.toString()
    });

    // Bundle submission is permissionless — the caller need not be a
    // registered endpoint. No registration precondition is enforced here.

    if (process.env.DRY_RUN === "1") {
        console.log(`\nDRY_RUN=1 — skipping submitBundle transaction`);
        return;
    }

    // ── Pre-flight replay check ───────────────────────────────────────────────
    // After a successful submitBundle, conn.receivedMessageId advances to the
    // proof's receivedMessageId value (= proofLeaf.nextMessageId - 1).
    // If already advanced the channel is used up — the user must run
    // verify:establish-channel again to rotate to a fresh slot.
    if (proofLeaf?.nextMessageId != null) {
        const expectedReceivedMsgId = BigInt(proofLeaf.nextMessageId) - 1n;
        if (expectedReceivedMsgId > 0n && conn.receivedMessageId >= expectedReceivedMsgId) {
            throwReplayError();
        }
    }

    // ── Gas estimation ────────────────────────────────────────────────────────
    let gas: bigint;
    try {
        gas = await clients.publicClient.estimateContractGas({
            address: service,
            abi: serviceArtifact.abi as never,
            functionName: "submitBundle",
            args: [channelId, proofHex],
            account: clients.account
        });
    } catch (err) {
        if (isReplayDetected(err)) throwReplayError();
        throw err;
    }

    console.log(`Estimated gas: ${gas}`);

    try {
        const {result} = await clients.publicClient.simulateContract({
            address: service,
            abi: serviceArtifact.abi as never,
            functionName: "submitBundle",
            args: [channelId, proofHex],
            account: clients.account,
            gas: 250_000_000n
        });
        console.log(`\nsimulateContract submitBundle: success`, result);
    } catch (err) {
        if (isReplayDetected(err)) throwReplayError();
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`\nsimulateContract submitBundle FAILED:\n${msg}`);
        process.exit(1);
    }

    let txHash: Hex;
    try {
        txHash = await clients.walletClient.writeContract({
            address: service,
            abi: serviceArtifact.abi as never,
            functionName: "submitBundle",
            args: [channelId, proofHex],
            gas: 16_000_000n
        });
    } catch (err) {
        if (isReplayDetected(err)) throwReplayError();
        throw err;
    }
    console.log(`\nsubmitBundle tx: ${txHash}`);
    const receipt = await clients.publicClient.waitForTransactionReceipt({hash: txHash});
    if (receipt.status !== "success") {
        throw new Error(`submitBundle reverted (tx ${txHash})`);
    }

    const after = (await clients.publicClient.readContract({
        address: service,
        abi: serviceArtifact.abi as never,
        functionName: "getChannel",
        args: [channelId]
    })) as {
        receivedMessageId: bigint;
        ackedMessageId: bigint;
        nextMessageId: bigint;
        receivedRunningHash: Hex;
    };

    console.log(`\nChannel after submit:`, {
        receivedMessageId: after.receivedMessageId.toString(),
        ackedMessageId: after.ackedMessageId.toString(),
        nextMessageId: after.nextMessageId.toString(),
        receivedRunningHash: after.receivedRunningHash
    });
    console.log(`\nBundle submitted successfully.`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
