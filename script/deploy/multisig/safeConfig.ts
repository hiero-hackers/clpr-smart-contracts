import {Hex} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import { envNumber, normalizePrivateKey } from "../shared/helpers";

/// Should be one-time deployments per chain
export interface SafeDeployment {
    singleton: `0x${string}`;
    factory: `0x${string}`;
}

/// Can be many deployments, each one is a safe-smart-account
export interface SafeAccountDeployment {
    account: `0x${string}`;
}

/// For deploying everything at once
export interface SafeFullDeployment extends SafeDeployment, SafeAccountDeployment {}

/// Params for deploying a new safe-smart-account
export interface SafeSetupParams {
    owners: `0x${string}`[];
    threshold: number;
    to?: `0x${string}`;
    data?: Hex;
    fallbackHandler?: `0x${string}`;
    paymentToken?: `0x${string}`;
    payment?: bigint;
    paymentReceiver?: `0x${string}`;
    saltNonce?: bigint;
}

/// Load deploy parameters from env.
export function loadSafeDeployParams(privateKey: string): SafeSetupParams {
    const pk = normalizePrivateKey(privateKey);
    const deployer = privateKeyToAccount(pk).address;

    // Owners: comma-separated list of addresses, defaults to deployer as sole owner
    const ownersRaw = process.env.SAFE_OWNERS ?? "";
    const owners: `0x${string}`[] =
        ownersRaw !== ""
            ? (ownersRaw.split(",").map((o) => o.trim()) as `0x${string}`[])
            : [deployer];

    return {
        owners,
        threshold: envNumber("SAFE_THRESHOLD", 1),
        to: (process.env.SAFE_TO as `0x${string}` | undefined) ?? undefined,
        data: (process.env.SAFE_DATA as Hex | undefined) ?? undefined,
        fallbackHandler: (process.env.SAFE_FALLBACK_HANDLER as `0x${string}` | undefined) ?? undefined,
        paymentToken: (process.env.SAFE_PAYMENT_TOKEN as `0x${string}` | undefined) ?? undefined,
        payment: process.env.SAFE_PAYMENT !== undefined ? BigInt(process.env.SAFE_PAYMENT) : undefined,
        paymentReceiver: (process.env.SAFE_PAYMENT_RECEIVER as `0x${string}` | undefined) ?? undefined,
        saltNonce: process.env.SAFE_SALT_NONCE !== undefined ? BigInt(process.env.SAFE_SALT_NONCE) : undefined
    };
}

export function loadSafeDeploymentFromEnv(): SafeDeployment {
    const req = (name: string): `0x${string}` => {
        const v = process.env[name];
        if (!v) throw new Error(`missing env ${name}`);
        return v as `0x${string}`;
    };
    return {
        singleton: req("SAFE_SINGLETON"),
        factory: req("SAFE_FACTORY"),
    };
}
