import {encodeAbiParameters, keccak256, type Hex} from "viem";

/// EVM storage slot derivation for `ClprService` (authoritative: `storage-layout.json`).

/// `_messageQueues` at root slot 1.
export const MESSAGE_QUEUES_SLOT = 1n;
/// `_channels` at root slot 15.
export const CHANNELS_SLOT = 15n;
/// Within MessageValue, `runningHashAfterProcessing` is struct offset +1.
export const MESSAGE_RUNNING_HASH_OFFSET = 1n;

/// Channel struct offsets proven by the EVM verifiers (ClprEvmBundleVerifier):
///   +1  verifier|status|nextMessageId
///   +2  ackedMessageId|receivedMessageId|nextExpectedReplyId
///   +4  sentRunningHash
///   +5  receivedRunningHash
///   +16 endpointManifestVersion (QueueMetadata proto field 7)
export const PROVEN_CHANNEL_OFFSETS = [1n, 2n, 4n, 5n, 16n] as const;

export function deriveMessageRunningHashSlot(channelId: Hex, messageId: bigint): Hex {
    const outer = BigInt(keccak256(encodeAbiParameters(
        [{type: "bytes32"}, {type: "uint256"}], [channelId, MESSAGE_QUEUES_SLOT]
    )));
    const inner = BigInt(keccak256(encodeAbiParameters(
        [{type: "uint256"}, {type: "uint256"}], [messageId, outer]
    )));
    const slot = (inner + MESSAGE_RUNNING_HASH_OFFSET) & ((1n << 256n) - 1n);
    return ("0x" + slot.toString(16).padStart(64, "0")) as Hex;
}

export function deriveMessagePayloadSlot(channelId: Hex, messageId: bigint): Hex {
    const outer = BigInt(keccak256(encodeAbiParameters(
        [{type: "bytes32"}, {type: "uint256"}], [channelId, MESSAGE_QUEUES_SLOT]
    )));
    const slot = BigInt(keccak256(encodeAbiParameters(
        [{type: "uint256"}, {type: "uint256"}], [messageId, outer]
    )));
    return ("0x" + slot.toString(16).padStart(64, "0")) as Hex;
}

export function deriveChannelBaseSlot(channelId: Hex): bigint {
    const encoded = encodeAbiParameters(
        [{type: "bytes32"}, {type: "uint256"}],
        [channelId, CHANNELS_SLOT]
    );
    return BigInt(keccak256(encoded));
}

export function deriveChannelFieldSlots(channelId: Hex): Hex[] {
    const baseSlot = deriveChannelBaseSlot(channelId);
    return PROVEN_CHANNEL_OFFSETS.map((off) => {
        const slotBig = (baseSlot + off) & ((1n << 256n) - 1n);
        return ("0x" + slotBig.toString(16).padStart(64, "0")) as Hex;
    });
}

/// Storage keys for QBFT bundle proof: last message running hash + 4 channel fields.
export function deriveQbftBundleStorageKeys(channelId: Hex, lastMessageId: bigint): Hex[] {
    return [deriveMessageRunningHashSlot(channelId, lastMessageId), ...deriveChannelFieldSlots(channelId)];
}
