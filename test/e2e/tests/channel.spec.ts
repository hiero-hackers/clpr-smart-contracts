import {afterAll, beforeAll, describe, expect, it} from "vitest";
import {createBackend} from "../backend/index.js";
import type {Backend} from "../backend/Backend.js";
import type {ChainClients} from "../lib/clients.js";
import {provisionE2ESuite} from "../lib/provisionSuite.js";
import {loadArtifact} from "../../../script/deploy/artifacts.js";
import {deployE2EPair, type DeployedAddresses} from "../deploy/deploy.js";
import {wireConfig} from "../deploy/wire.js";
import {wireChannel, type WiredChannel} from "../deploy/wireChannel.js";

/// Phase B: wire a CLPR channel between two chains and assert both sides
/// end up with byte-identical channelId and ACTIVE status.
///
/// This is the foundation for the roundtrip suite: anything that ships a
/// message between A and B needs a live channel on both sides first.
describe("channel", () => {
    let backend: Backend;
    let A: ChainClients;
    let B: ChainClients;
    let addrsA: DeployedAddresses;
    let addrsB: DeployedAddresses;
    let channel: WiredChannel;

    beforeAll(async () => {
        backend = createBackend();
        await backend.start();

        const suite = await provisionE2ESuite(backend, "channel");
        A = suite.clientsA;
        B = suite.clientsB;

        ({addrsA, addrsB} = await deployE2EPair({
            clientsA: A,
            clientsB: B,
            privateKey: suite.privateKey,
            protocolVersion: 1,
            caipChainIdA: backend.caipA(),
            caipChainIdB: backend.caipB()
        }));

        await wireConfig({clients: A, addrs: addrsA, soloRelay: backend.kindA() === "solo"});
        await wireConfig({clients: B, addrs: addrsB, soloRelay: backend.kindB() === "solo"});

        channel = await wireChannel({
            chainA: A, chainB: B,
            caipA: backend.caipA(), caipB: backend.caipB(),
            addrsA, addrsB
        });
    }, 600_000);

    afterAll(async () => {
        await backend?.stop();
    });

    it("derived a non-zero channelId", () => {
        expect(channel.channelId).toMatch(/^0x[0-9a-fA-F]{64}$/);
        expect(channel.channelId).not.toBe(`0x${"00".repeat(32)}`);
    });

    it("channelId is identical on both chains (cross-platform byte equivalence)", async () => {
        const service = loadArtifact("ClprService");
        const onA = (await A.publicClient.readContract({
            address: addrsA.clprService,
            abi: service.abi as never,
            functionName: "getChannel",
            args: [channel.channelId]
        })) as {channelId: `0x${string}`; status: number};
        const onB = (await B.publicClient.readContract({
            address: addrsB.clprService,
            abi: service.abi as never,
            functionName: "getChannel",
            args: [channel.channelId]
        })) as {channelId: `0x${string}`; status: number};
        expect(onA.channelId).toEqual(channel.channelId);
        expect(onB.channelId).toEqual(channel.channelId);
    });

    it("channel is ACTIVE with correct initial storage slot values on both chains", async () => {
        const service = loadArtifact("ClprService");
        // ClprTypes.ChannelStatus: PENDING=0, ACTIVE=1, PAUSED=2, CLOSING=3, DRAINED=4, CLOSED=5
        const ACTIVE = 1;

        const onA = (await A.publicClient.readContract({
            address: addrsA.clprService,
            abi: service.abi as never,
            functionName: "getChannel",
            args: [channel.channelId]
        })) as {
            status: number;
            nextMessageId: bigint;
            ackedMessageId: bigint;
            receivedMessageId: bigint;
            nextExpectedReplyId: bigint;
            sentRunningHash: `0x${string}`;
            receivedRunningHash: `0x${string}`;
            verifier: `0x${string}`;
            chainId: string;
        };
        const onB = (await B.publicClient.readContract({
            address: addrsB.clprService,
            abi: service.abi as never,
            functionName: "getChannel",
            args: [channel.channelId]
        })) as {
            status: number;
            nextMessageId: bigint;
            ackedMessageId: bigint;
            receivedMessageId: bigint;
            nextExpectedReplyId: bigint;
            sentRunningHash: `0x${string}`;
            receivedRunningHash: `0x${string}`;
            verifier: `0x${string}`;
            chainId: string;
        };
        
        // Validate storage slots: both channels are ACTIVE
        expect(onA.status).toBe(ACTIVE);
        expect(onB.status).toBe(ACTIVE);
        
        // Validate storage slots: initial message IDs are correct
        expect(onA.nextMessageId).toBe(1n);
        expect(onA.ackedMessageId).toBe(0n);
        expect(onA.receivedMessageId).toBe(0n);
        expect(onA.nextExpectedReplyId).toBe(1n);
        expect(onB.nextMessageId).toBe(1n);
        expect(onB.ackedMessageId).toBe(0n);
        expect(onB.receivedMessageId).toBe(0n);
        expect(onB.nextExpectedReplyId).toBe(1n);
        
        // Validate storage slots: running hashes are initialized to zero (no messages yet)
        expect(onA.sentRunningHash).toBe("0x0000000000000000000000000000000000000000000000000000000000000000");
        expect(onA.receivedRunningHash).toBe("0x0000000000000000000000000000000000000000000000000000000000000000");
        expect(onB.sentRunningHash).toBe("0x0000000000000000000000000000000000000000000000000000000000000000");
        expect(onB.receivedRunningHash).toBe("0x0000000000000000000000000000000000000000000000000000000000000000");
        
        // Validate storage slots: verifiers are set correctly
        expect(onA.verifier.toLowerCase()).toBe(addrsA.verifier.toLowerCase());
        expect(onB.verifier.toLowerCase()).toBe(addrsB.verifier.toLowerCase());
        
        // Validate storage slots: peer chainIds are correct
        expect(onA.chainId).toBe(backend.caipB());
        expect(onB.chainId).toBe(backend.caipA());
    });

    it("channelCount = 1 on both chains", async () => {
        const service = loadArtifact("ClprService");
        const cntA = (await A.publicClient.readContract({
            address: addrsA.clprService,
            abi: service.abi as never,
            functionName: "channelCount"
        })) as bigint;
        const cntB = (await B.publicClient.readContract({
            address: addrsB.clprService,
            abi: service.abi as never,
            functionName: "channelCount"
        })) as bigint;
        expect(cntA).toBe(1n);
        expect(cntB).toBe(1n);
    });
});
