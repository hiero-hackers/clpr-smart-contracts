/// Resolve a foundry.toml rpc alias or pass through a full URL.
export function resolveRpcUrl(rpc: string): string {
    if (rpc.startsWith("http://") || rpc.startsWith("https://")) return rpc;
    if (rpc === "anvil") return "http://127.0.0.1:8545";
    if (rpc === "besu") {
        const url = process.env.BESU_RPC;
        if (!url) throw new Error("BESU_RPC is not set (required for --rpc besu without a full URL)");
        return url;
    }
    if (rpc === "hiero") {
        const url = process.env.HIERO_RPC;
        if (!url) throw new Error("HIERO_RPC is not set (required for --rpc hiero without a full URL)");
        return url;
    }
    throw new Error(`unknown rpc alias "${rpc}" — pass a full http(s) URL or anvil/besu/hiero`);
}
