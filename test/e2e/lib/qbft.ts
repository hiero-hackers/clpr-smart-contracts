import {encodeAbiParameters, getAddress, type Hex} from "viem";

export const QBFT_EPOCH_LENGTH = 30000n;

/// ABI-encode the 4-field QBFT trust anchor stored in Channel.trustAnchor.
/// Must match QBFTVerifier._decodeTrustAnchor: abi.encode(validator, codeHash, epochLength, epochNumber)
/// (128 bytes). The service address and channelId are carried in the ChannelContext, not the anchor.
export function encodeTrustAnchor(
    validator: Hex,
    codeHash: Hex,
    epochLength: bigint,
    epochNumber: bigint
): Hex {
    return encodeAbiParameters(
        [{type: "address"}, {type: "bytes32"}, {type: "uint64"}, {type: "uint64"}],
        [getAddress(validator), codeHash, epochLength, epochNumber]
    ) as Hex;
}

let _rpcId = 0;

export async function rpcCall<T>(rpcUrl: string, method: string, params: unknown[] = []): Promise<T> {
    const body = JSON.stringify({jsonrpc: "2.0", method, params, id: ++_rpcId});
    const res = await fetch(rpcUrl, {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body
    });
    const json = (await res.json()) as {result?: T; error?: {message: string}};
    if (json.error) throw new Error(`RPC ${method}: ${json.error.message}`);
    return json.result as T;
}

export async function waitForBlock(rpcUrl: string, minBlock = 1, timeoutMs = 60_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        try {
            const latest = await rpcCall<string>(rpcUrl, "eth_blockNumber");
            if (parseInt(latest, 16) >= minBlock) return;
        } catch {
            // node not ready yet
        }
        await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error(`chain at ${rpcUrl} did not reach block ${minBlock} within ${timeoutMs}ms`);
}
