# Verification inputs (state proof → submitBundle)

Submit real `stateProof.bin` through `ClprService.submitBundle` using production `HieroVerifier`.

## Quick path

```bash
forge build
npm run e2e:up          # Besu, or use Anvil on :8545
# deploy ClprService, set CLPR_SERVICE + PRIVATE_KEY + BESU_RPC_A in .env

npm run verify:establish-channel   # deploy Hiero stack (deployWithHieroVerifier.ts), wire channel + endpoint
# optional full stack: npm run deploy:e2e-with-hiero-verifier -- --rpc-url besu
npm run verify:proof                  # submitBundle(stateProof.bin)
```

`establish-channel` is only plumbing (channel + endpoint). The check you care about is **`verify:proof`**.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SUBMIT_RPC` | `BESU_RPC_A` | Where `submitBundle` is sent |
| `DRY_RUN` | off | `1` = eth_call only, no tx |
| `HIERO_VERIFIER` | deploy | Reuse verifier after `forge build` |

## Inputs

- `stateProof.bin` — Hiero state proof (submitted on-chain)
- `stateProof.json` — same proof, JSON (decoded for logging; channel leaf in path 0)
- `trustAnchor.bin` — 32-byte ledger id (`HieroVerifier` constructor)

## Troubleshooting

| Symptom | Cause |
|---------|--------|
| `HieroHintsFinalPairingFailed` | hinTS pairing failed on local RPC (Anvil/Besu vs Hiero node) |
| `ClprChannelAlreadyExists` (`0xbcb71195`) | Channel already exists — establish skips register/complete |
| `getChannel` / `0x3a469e89` | Normal on fresh chain — means run establish-channel (not an error) |
| `ClprEndpointNotRegistered` | Run `verify:establish-channel` |
| `ClprInvalidChannelId` | Re-run establish-channel (stale `.channel.json`) |

After changing `HieroVerifier.sol`, redeploy the verifier and re-run establish-channel.
