const CORE_MANAGED_KEYS = [
    "SAFE_SINGLETON",
    "SAFE_FACTORY",
    "OWNER_ACCOUNT"
] as const;

const MANAGED_KEYS = [...CORE_MANAGED_KEYS] as const;

export type ManagedEnvKey = (typeof MANAGED_KEYS)[number];

export function safeDeployedToEnv(
    d: Partial<{
        singleton: string;
        factory: string;
        account: string;
    }>
): Partial<Record<ManagedEnvKey, string>> {
    const out: Partial<Record<ManagedEnvKey, string>> = {};
    if (d.singleton) out.SAFE_SINGLETON = d.singleton;
    if (d.factory) out.SAFE_FACTORY = d.factory;
    if (d.account) out.OWNER_ACCOUNT = d.account;
    return out;
}

export {MANAGED_KEYS};
