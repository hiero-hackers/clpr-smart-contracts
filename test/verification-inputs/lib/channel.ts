import type {Hex, PublicClient} from "viem";
import {loadArtifact} from "../../../script/deploy/artifacts.js";
import {Throttles} from "../../../script/deploy";

/** ClprTypes.ChannelStatus — must match src/libraries/ClprTypes.sol */
export const ChannelStatus = {
    PENDING: 0,
    ACTIVE: 1,
    PAUSED: 2,
    CLOSING: 3,
    DRAINED: 4,
    CLOSED: 5
} as const;

export const CLPR_CHANNEL_NOT_FOUND = "0x3a469e89";
export const CLPR_CHANNEL_ALREADY_EXISTS = "0xbcb71195";

export type OnChainChannel = {
    channelId: Hex;
    verifier: Hex;
    status: number;
    trustAnchor: Hex;
    chainId: string;
    ackedMessageId: bigint;
    receivedMessageId: bigint;
    nextMessageId: bigint;
    sentRunningHash?: Hex;
    receivedRunningHash?: Hex;
    peerThrottles?: Throttles;
};

function revertSelector(err: unknown): Hex | undefined {
    let cur: unknown = err;
    for (let i = 0; i < 6 && cur; i++) {
        if (typeof cur === "object" && cur !== null) {
            const o = cur as Record<string, unknown>;
            if (typeof o.signature === "string") return o.signature as Hex;
            if (typeof o.raw === "string") return o.raw as Hex;
            if (typeof o.data === "string") return o.data as Hex;
            cur = o.cause;
        } else break;
    }
    const msg = err instanceof Error ? err.message : String(err);
    const m = msg.match(/0x[a-fA-F0-9]{8}/);
    return m ? (m[0] as Hex) : undefined;
}

export function isChannelNotFound(err: unknown): boolean {
    const sel = revertSelector(err);
    return sel === CLPR_CHANNEL_NOT_FOUND || (msgIncludes(err, "3a469e89"));
}

function msgIncludes(err: unknown, hex: string): boolean {
    const msg = err instanceof Error ? err.message : String(err);
    return msg.includes(hex) || msg.includes(hex.slice(2));
}

/** Returns null when the channel id has never been completed on-chain. */
export async function readChannel(
    publicClient: PublicClient,
    service: Hex,
    channelId: Hex
): Promise<OnChainChannel | null> {
    const artifact = loadArtifact("ClprService");
    try {
        return (await publicClient.readContract({
            address: service,
            abi: artifact.abi as never,
            functionName: "getChannel",
            args: [channelId]
        })) as OnChainChannel;
    } catch (err) {
        if (isChannelNotFound(err)) return null;
        throw err;
    }
}

export function channelStatusLabel(status: number): string {
    const name = Object.entries(ChannelStatus).find(([, v]) => v === status)?.[0];
    return name ?? String(status);
}
