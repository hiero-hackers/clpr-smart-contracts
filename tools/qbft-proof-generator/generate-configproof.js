#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { RLP } from "@ethereumjs/rlp";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = join(resolve(__dirname, "..", ".."), "test", "verifiers", "qbft", "fixtures");

// Read fixtures
const trustAnchorHex = readFileSync(join(FIXTURES_DIR, "trustAnchor.hex"), "utf-8").trim();
const bundlePayloadHex = readFileSync(join(FIXTURES_DIR, "bundlePayload.hex"), "utf-8").trim();
const validatorHex = readFileSync(join(FIXTURES_DIR, "validatorAddress.hex"), "utf-8").trim();

const bundleDecoded = RLP.decode(Buffer.from(bundlePayloadHex, "hex"));
const headerDecoded = bundleDecoded[0]; // decoded array — RLP.encode inlines it as a list

// The peer service address baked into the trust anchor is the address
// the bundle's account proof is verified against.
const trustAnchorDecoded = RLP.decode(Buffer.from(trustAnchorHex, "hex"));
const serviceAddress = Buffer.from(trustAnchorDecoded[1]);

function encodeUint(n) {
    if (n === 0n) return Buffer.alloc(0);
    let hex = n.toString(16);
    if (hex.length % 2 !== 0) hex = "0" + hex;
    return Buffer.from(hex, "hex");
}

const throttles = [
    encodeUint(100n),       // maxMessagesPerBundle
    encodeUint(100_000n),   // maxMessagePayloadBytes
    encodeUint(1_000_000n), // maxGasPerMessage
    encodeUint(1_000n),     // maxQueueDepth
    encodeUint(100_000n),   // maxSyncBytes
];

// epochLength must match genesis.json qbft.epochlength.
const EPOCH_LENGTH = 30_000n;

// Build configProof
const configProof = RLP.encode([
    Buffer.from(validatorHex.replace("0x", ""), "hex"),   // 0 validatorAddr
    serviceAddress,                                       // 1 serviceAddr
    Buffer.alloc(32, 0),                                  // 2 codeHash
    Buffer.from("eip155:1"),                              // 3 chainId
    Buffer.alloc(0),                                      // 4 peerConfigNanos
    throttles,                                            // 5 throttles (RLP list of 5 uint64s)
    Buffer.from(trustAnchorHex, "hex"),                   // 6 trustAnchor (raw bytes)
    Buffer.alloc(0),                                      // 7 trustAnchorId empty
    headerDecoded,                                        // 8 blockHeader inlined as RLP list
    encodeUint(EPOCH_LENGTH),                             // 9 epochLength
]);

const decoded = RLP.decode(configProof);
console.assert(decoded.length === 10, "Expected 10 items in configProof");

writeFileSync(join(FIXTURES_DIR, "configProof.hex"), Buffer.from(configProof).toString("hex") + "\n");
writeFileSync(join(FIXTURES_DIR, "serviceAddress.hex"), serviceAddress.toString("hex") + "\n");

console.log("✅ Generated configProof:", configProof.length, "bytes");
console.log("Starts with:", Buffer.from(configProof).toString("hex").slice(0, 60));
