import {pbBytes, pbInt, pbLen} from "../lib/proto.js";

export interface ParsedContractId {
    shard: bigint;
    realm: bigint;
    num: bigint;
}

/// Parse mirror `0.0.12345` contract id.
export function parseContractId(contractId: string): ParsedContractId {
    const parts = contractId.split(".");
    if (parts.length !== 3) throw new Error(`invalid contract id: ${contractId}`);
    return {shard: BigInt(parts[0]), realm: BigInt(parts[1]), num: BigInt(parts[2])};
}

/// Encode `proto.SlotKey` (contractID + 32-byte EVM storage key).
export function encodeSlotKey(contractId: string, evmSlotHex: string): Buffer {
    const {shard, realm, num} = parseContractId(contractId);
    const contractIdMsg = Buffer.concat([
        pbInt(1, shard),
        pbInt(2, realm),
        pbInt(3, num)
    ]);
    const key = Buffer.from(evmSlotHex.replace("0x", "").padStart(64, "0"), "hex");
    return Buffer.concat([
        pbLen(1, contractIdMsg),
        pbBytes(2, key)
    ]);
}

/// Encode `proto.ContractID` sub-message.
export function encodeContractId(contractId: string): Buffer {
    const {shard, realm, num} = parseContractId(contractId);
    return Buffer.concat([pbInt(1, shard), pbInt(2, realm), pbInt(3, num)]);
}
