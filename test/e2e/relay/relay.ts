/// Relay skeleton — placeholder for the bidirectional message-shuttling loop.
///
/// Final shape (to be filled when roundtrip.spec.ts comes online):
///   1. subscribe to `MessageQueued` events on chain X via publicClient.watchEvent
///   2. for each event, read MessageValue via `getMessage(channelId, messageId)`
///   3. build a ClprBundleContent protobuf bundle: QueueMetadata + [payload...]
///   4. submit on chain Y as registered endpoint via `submitBundle(channelId, proofBytes)`
///   5. observe `BundleProcessed` / `MessageDispatched` on Y, log status
///
/// Encoder lives in `encodeBundle.ts` (TODO) — must match the on-chain
/// decoder in `src/libraries/codec/ClprProtobuf.sol`.

export interface RelayHandles {
    stop(): Promise<void>;
}

export async function startRelay(): Promise<RelayHandles> {
    return {
        stop: async () => {}
    };
}
