/// TypeScript port of the CLPR identifier derivations.
/// These MUST byte-for-byte match the Solidity originals:
///   - ClprService._deriveChannelId             (src/logic/ChannelLogic.sol)
///   - ConnectorLib.deriveConnectorId              (src/libraries/service/ConnectorLib.sol)
/// and the commitment / signature hashes derived in:
///   - ChannelLogic._verifySignature, ConnectorLib._verifyConnectorSig
/// If you change anything here, update those source files in lockstep and
/// the corresponding `Cross-platform byte-equivalence checklist` in
/// docs/lifecycle.md.

import {keccak256, toBytes, toHex, concat, encodePacked, type Hex} from "viem";

/// keccak256(loChain || hiChain || pubKey || salt) where (lo, hi) is
/// (localChainId, peerChainId) sorted by keccak256 of their UTF-8 bytes.
/// Matches Solidity's `_deriveChannelId` in ChannelLogic.sol.
export function deriveChannelId(args: {
    localChainId: string;
    peerChainId: string;
    pubKey: Hex;                 // 64-byte uncompressed secp256k1 (X || Y), no 0x04 prefix
    salt: Hex;                   // bytes32
}): Hex {
    const a = toBytes(args.localChainId);   // UTF-8 bytes of the chain ID string
    const b = toBytes(args.peerChainId);
    const aHash = keccak256(a);
    const bHash = keccak256(b);
    const [lo, hi] = aHash <= bHash ? [a, b] : [b, a];

    // abi.encodePacked(string, string, bytes, bytes32) → just concatenation
    return keccak256(concat([lo, hi, toBytes(args.pubKey), toBytes(args.salt)]));
}

/// abi.encodePacked(keccak256(channelId || pubKey || salt))
/// Note: the on-chain function returns `bytes` (a wrapped bytes32 cast),
/// so the value is the 32-byte hex with the 0x prefix.
/// Matches `ConnectorLib.deriveConnectorId`.
export function deriveConnectorId(args: {
    channelId: Hex;           // bytes32
    pubKey: Hex;                 // 64 bytes
    salt: Hex;                   // bytes32
}): Hex {
    return keccak256(
        concat([toBytes(args.channelId), toBytes(args.pubKey), toBytes(args.salt)])
    );
}

/// keccak256(channelId || pubKey) — the commit value passed to registerChannel.
export function channelCommitment(channelId: Hex, pubKey: Hex): Hex {
    return keccak256(concat([toBytes(channelId), toBytes(pubKey)]));
}

/// keccak256(connectorId || pubKey) — the commit value passed to registerConnector.
/// `connectorId` is the bytes32 value from the deriveConnectorId step.
export function connectorCommitment(connectorId: Hex, pubKey: Hex): Hex {
    return keccak256(concat([toBytes(connectorId), toBytes(pubKey)]));
}

/// The message hashed and signed for the channel-reveal signature:
///   "\x19Ethereum Signed Message:\n32" ‖ keccak256(channelId ‖ routerAddress)
/// Caller should pass the resulting digest to viem's `signMessage` with
/// `message: { raw: <digest> }`, which prepends the prefix and re-hashes.
/// We return the INNER hash (the one viem will then prefix); use as
///   `signMessage({ account, message: { raw: digestForChannelReveal(...) } })`.
export function digestForChannelReveal(channelId: Hex, routerAddress: Hex): Hex {
    return keccak256(encodePacked(["bytes32", "address"], [channelId, routerAddress]));
}

/// Inner digest for the connector-reveal signature. Same prefix scheme as
/// digestForChannelReveal, but binds to connectorId (bytes32).
export function digestForConnectorReveal(connectorId: Hex, routerAddress: Hex): Hex {
    return keccak256(encodePacked(["bytes32", "address"], [connectorId, routerAddress]));
}

/// Convenience: a deterministic 64-byte uncompressed secp256k1 pubkey from
/// a viem-style Account. Drops the 0x04 prefix that secp256k1 libraries add.
/// `account.publicKey` is the 65-byte uncompressed (0x04 + X + Y).
export function uncompressedPubKey64(publicKey: Hex): Hex {
    const bytes = toBytes(publicKey);
    if (bytes.length === 65 && bytes[0] === 0x04) {
        return toHex(bytes.slice(1)) as Hex;
    }
    if (bytes.length === 64) return publicKey;
    throw new Error(`expected 64- or 65-byte pubkey, got ${bytes.length} bytes`);
}
