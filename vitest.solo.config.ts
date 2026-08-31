import {defineConfig} from "vitest/config";

/// Solo relays + shared funders cannot handle parallel spec files (nonce collisions, forge broadcast races).
/// Hedera/Solo transaction finality is slow — bump hookTimeout and testTimeout well beyond viem's defaults.
export default defineConfig({
    test: {
        globalSetup: ["test/e2e/backend/solo/solo.ts"],
        include: ["test/e2e/**/*.spec.ts"],
        globals: true,
        testTimeout: 300_000,
        hookTimeout: 600_000,
        setupFiles: ["test/e2e/backend/solo/soloSetup.ts"],
        pool: "forks",
        fileParallelism: false,
        maxWorkers: 1,
        sequence: {concurrent: false},
        reporters: process.env.CI ? ["default", "junit"] : ["default"],
        outputFile: process.env.CI ? "junit.xml" : undefined
    }
});
