export function requireEnv(names: string[], envFile: string): void {
    const missing = names.filter((n) => !process.env[n]);
    if (missing.length > 0) {
        throw new Error(
            `missing required env: ${missing.join(", ")} (set in ${envFile} or export in your shell)`
        );
    }
}

export function normalizePk(envFile: string): `0x${string}` {
    const pk = process.env.PRIVATE_KEY;
    if (!pk) {
        throw new Error(`PRIVATE_KEY is required (set in ${envFile} or export in your shell)`);
    }
    return (pk.startsWith("0x") ? pk : `0x${pk}`) as `0x${string}`;
}

export function envNumber(name: string, fallback: number): number {
    const raw = process.env[name];
    if (raw === undefined || raw === "") return fallback;
    return Number(raw);
}

export function normalizePrivateKey(pk: string): `0x${string}` {
    return (pk.startsWith("0x") ? pk : `0x${pk}`) as `0x${string}`;
}
