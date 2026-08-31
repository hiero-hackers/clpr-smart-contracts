import {afterAll, beforeAll, describe, expect, it} from "vitest";
import {encodeFunctionData} from "viem";
import type {Abi, Hex} from "viem";
import {createBackend} from "../backend/index.js";
import type {Backend} from "../backend/Backend.js";
import type {ChainClients} from "../lib/clients.js";
import {provisionE2ESuite} from "../lib/provisionSuite.js";
import {loadArtifact} from "../../../script/deploy/artifacts.js";
import {deployE2EPair, type DeployedAddresses} from "../deploy/deploy.js";
import {wireConfig, registerEndpoint} from "../deploy/wire.js";
import {wireChannel, type WiredChannel} from "../deploy/wireChannel.js";

// Malformed Protobuf Handling
//
// Each test submits a distinct kind of malformed bundle and asserts the SPECIFIC
// reason submitBundle reverts with (surfaced by simulateContract), not just that
// it reverts. The reasons cluster into a few groups by design:
//   - Wire-level malformation: input that runs off the end of the buffer rejects the whole
//     bundle, same as  varint too wide for uint64.
//     The decode helpers fail closed before they produce partial data.
//   - Strict wire format: a field number outside the negotiated protocol version's
//     schema rejects the whole bundle with ClprUnknownWireField. Extra fields from a
//     same-version peer are a protocol violation, never skipped.
//   - Bundles that decode to an empty/default shape fail the downstream
//     progress/replay invariants (NoProgress / ClprBundleVerificationFailed).

// Foundry tests based in Solidity won't allow us to prepare a request
// containing structurally broken input like non-hex input / malformed hex — those
// malformations live below the ABI layer, where `bytes`/`bytes32` are already
// well-formed by construction. viem's client refuses to send them too, so we
// hand-build the JSON-RPC request and post it with fetch. The node rejects such
// calldata at the RPC parse layer (before execution), which gates every call and
// transaction — so a submitBundle tx with this calldata never reaches the contract.

const service = loadArtifact("ClprService");

// These errors are raised inside delegatecalled logic libraries, so they are not
// in the router (ClprService) ABI. Add them so viem decodes the revert into a
// readable name instead of a bare 4-byte selector.
const EXTRA_ERRORS = [
    {type: "error", name: "NoProgress", inputs: []},
    {type: "error", name: "ClprReplayDetected", inputs: []},
    {type: "error", name: "ClprBundleVerificationFailed", inputs: []},
    {type: "error", name: "ClprUnknownWireField", inputs: [{name: "fieldNumber", type: "uint64"}]},
    // Raised by the bounds-checked protobuf decode helpers on wire-level malformation.
    {type: "error", name: "TruncatedInput", inputs: []},
    {type: "error", name: "VarintOverflow", inputs: []}
] as const;
const ABI = [...(service.abi as Abi), ...EXTRA_ERRORS] as Abi;

// Valid 74-byte QueueMetadata body (state = ACTIVE) reused by the structural cases.
const META_ACTIVE = "0801" + "1220" + "00".repeat(32) + "1800" + "2220" + "00".repeat(32) + "2801";
// Same but with an out-of-range status enum (99) in field 5.
const META_BAD_STATUS = "0801" + "1220" + "00".repeat(32) + "1800" + "2220" + "00".repeat(32) + "2863";

/// field 1 (metadata) length-delimited wrapper: 0x0a || varint(len) || body. len < 128.
function wrapMetadata(bodyHex: string): string {
    return "0a" + (bodyHex.length / 2).toString(16).padStart(2, "0") + bodyHex;
}

const METADATA_ACTIVE = wrapMetadata(META_ACTIVE);

// REPLY message (field 2) carrying an out-of-range status enum (255), as in the original fixture.
const REPLY_INNER = "0801" + "10ff01" + "1a00";
const REPLY_MSG = "12" + ((REPLY_INNER.length / 2) - 2).toString(16).padStart(2, "0")
    + "0a" + ((REPLY_INNER.length / 2) - 2).toString(16).padStart(2, "0") + REPLY_INNER;

interface MalformedCase {
    name: string;
    bundle: Hex;
    /// Expected revert reason (matched against the surfaced revert message).
    reason: RegExp;
}

const CASES: MalformedCase[] = [
    {name: "completely empty bundle", bundle: "0x", reason: /NoProgress/},
    {name: "truncated field key", bundle: "0x08", reason: /TruncatedInput/},
    {name: "invalid varint encoding", bundle: "0x0a80", reason: /TruncatedInput/},
    {name: "length-delimited field claiming more bytes than available", bundle: "0x0aff01", reason: /TruncatedInput/},
    {name: "truncated length-delimited data", bundle: "0x0a05010203", reason: /TruncatedInput/},
    {name: "invalid wire type", bundle: "0x07", reason: /ClprUnknownWireField/},
    {name: "missing metadata field", bundle: "0x1200", reason: /NoProgress/},
    {name: "malformed metadata structure", bundle: "0x0a03080100", reason: /ClprUnknownWireField/},
    {name: "invalid running hash length", bundle: ("0x0a1a08011210" + "00".repeat(16)) as Hex, reason: /TruncatedInput/},
    {name: "invalid channel status enum value", bundle: ("0x" + wrapMetadata(META_BAD_STATUS)) as Hex, reason: /ClprBundleVerificationFailed/},
    {name: "message payload having unknown message type", bundle: ("0x" + METADATA_ACTIVE + "1203c20600") as Hex, reason: /NoProgress/},
    {name: "nested message having truncated data", bundle: ("0x" + METADATA_ACTIVE + "12040a050a01") as Hex, reason: /NoProgress/},
    {name: "deeply nested invalid structure", bundle: ("0x" + METADATA_ACTIVE + "1a040aff01") as Hex, reason: /ClprUnknownWireField/},
    {name: "varint overflow", bundle: ("0x08" + "ff".repeat(11) + "01") as Hex, reason: /VarintOverflow/},
    {name: "reply message containing invalid status enum", bundle: ("0x" + METADATA_ACTIVE + REPLY_MSG) as Hex, reason: /ClprUnknownWireField/},
    {name: "garbage bytes appended", bundle: ("0x" + METADATA_ACTIVE + "deadbeefcafebabe") as Hex, reason: /TruncatedInput/}
];

describe("malformed protobuf bundles", () => {
    let backend: Backend;
    let A: ChainClients;
    let B: ChainClients;
    let addrsA: DeployedAddresses;
    let addrsB: DeployedAddresses;
    let channel: WiredChannel;

    beforeAll(async () => {
        backend = createBackend();
        await backend.start();

        const suite = await provisionE2ESuite(backend, "malformed");
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

        const fakeKey = ("0x" + "11".repeat(64)) as `0x${string}`;
        await registerEndpoint({clients: A, clprService: addrsA.clprService, signingKey: fakeKey, soloRelay: backend.kindA() === "solo"});
        await registerEndpoint({clients: B, clprService: addrsB.clprService, signingKey: fakeKey, soloRelay: backend.kindB() === "solo"});

        channel = await wireChannel({
            chainA: A, chainB: B,
            caipA: backend.caipA(), caipB: backend.caipB(),
            addrsA, addrsB
        });
    }, 600_000);

    afterAll(async () => {
        await backend?.stop();
    });

    for (const c of CASES) {
        it(`rejects bundle with ${c.name}`, async () => {
            await expect(
                B.publicClient.simulateContract({
                    address: addrsB.clprService,
                    abi: ABI as never,
                    functionName: "submitBundle",
                    args: [channel.channelId, c.bundle],
                    account: B.account
                })
            ).rejects.toThrow(c.reason);
        }, 30_000);
    }

    /// POSTs a raw eth_call to chain B's JSON-RPC with arbitrary `data`, bypassing viem's
    /// client-side hex validation. Rejects with the node's error message when the RPC layer
    /// refuses the request, so tests can assert the rejection reason.
    async function rawEthCall(data: string): Promise<unknown> {
        const res = await fetch(backend.rpcB(), {
            method: "POST",
            headers: {"content-type": "application/json"},
            body: JSON.stringify({
                jsonrpc: "2.0",
                id: 1,
                method: "eth_call",
                params: [{from: B.account.address, to: addrsB.clprService, data}, "latest"]
            })
        });
        const body = (await res.json()) as {result?: unknown; error?: {message: string}};
        if (body.error) throw new Error(body.error.message);
        return body.result;
    }

    /// A well-formed submitBundle calldata that we then corrupt at the hex level.
    function validSubmitCalldata(): string {
        return encodeFunctionData({
            abi: ABI,
            functionName: "submitBundle",
            args: [channel.channelId, ("0x" + METADATA_ACTIVE) as Hex]
        });
    }

    it("rejects submitBundle calldata containing non-hex characters", async () => {
        // Replace the final nibble of valid calldata with a non-hex character.
        const nonHex = validSubmitCalldata().slice(0, -1) + "Z";
        await expect(rawEthCall(nonHex)).rejects.toThrow();
    }, 30_000);

    it("rejects submitBundle calldata with odd-length hex", async () => {
        // Drop the final nibble so the hex string has an odd number of digits.
        const oddLength = validSubmitCalldata().slice(0, -1);
        await expect(rawEthCall(oddLength)).rejects.toThrow();
    }, 30_000);
}, 180_000);
