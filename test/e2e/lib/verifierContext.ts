/// Verifier-specific constants for cross-chain E2E (not part of backend transport).

/// Account #0 from Besu genesis — sole QBFT validator in genesis-a/b.json.
export const QBFT_VALIDATOR = "0xf39Fd6e51aad88F6f4ce6aB8827279cffFb92266" as const;

export function resolveQbftValidator(): `0x${string}` {
    const v = process.env.CLPR_QBFT_VALIDATOR;
    if (!v) return QBFT_VALIDATOR;
    return (v.startsWith("0x") ? v : `0x${v}`) as `0x${string}`;
}
