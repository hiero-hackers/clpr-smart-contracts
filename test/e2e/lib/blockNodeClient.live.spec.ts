import {describe, expect, it} from "vitest";
import {
    getLatestBlock,
    getStateProof,
    isProofServiceNotImplementedError,
    PROOF_SERVICE_NOT_IMPLEMENTED_MSG
} from "./blockNodeClient.js";
import {encodeSlotKey} from "./slotKey.js";

describe.runIf(!!process.env.CLPR_SOLO_BLOCK_NODE)("block node client (live)", () => {
    const host = process.env.CLPR_SOLO_BLOCK_NODE!;

    it("getBlock returns TSS signed_block_proof", async () => {
        const b = await getLatestBlock(host);
        expect(b.blockNumber).toBeGreaterThan(0n);
        expect(b.signedBlockProof.length).toBeGreaterThan(100);
        expect(b.items.length).toBeGreaterThan(0);
    });

    it("getStateProof throws on block node v0.33.x (ProofService not implemented)", async () => {
        const b = await getLatestBlock(host);
        await expect(
            getStateProof(host, b.blockNumber, encodeSlotKey("0.0.100", `0x${"11".repeat(32)}`))
        ).rejects.toSatisfy((err: unknown) => {
            expect(isProofServiceNotImplementedError(err)).toBe(true);
            expect((err as Error).message).toContain(PROOF_SERVICE_NOT_IMPLEMENTED_MSG);
            return true;
        });
    });
});
