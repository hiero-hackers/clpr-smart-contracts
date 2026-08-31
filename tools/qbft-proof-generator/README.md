# QBFT Besu proof generator

This directory holds a pre-generated RLP-encoded bundle payload that was captured from a real Besu QBFT node.

## Re-generating the fixture

```bash
cd tools/qbft-proof-generator
node generate-fixture.js
```

Prerequisites:
- Docker (for the Besu QBFT node)
- Node.js 22+

### What the script does

`generate-fixture.js`:
1. Starts a 3-validator QBFT Besu cluster via docker-compose
2. **Bootstraps `configProof.hex`** from an early block so the Forge script can proceed
3. Deploys ClprService + completes a channel via `QbftFixtureSetup.s.sol`
4. Calls `eth_getProof` to capture real Merkle Patricia proofs
5. RLP-encodes everything into `bundlePayload.hex`, `trustAnchor.hex`, `validatorAddress.hex`
6. Overwrites `configProof.hex` with the final version containing the real trust anchor
   (service address + codeHash) and the bundle block header
7. Writes `serviceAddress.hex`
8. Stops the Besu cluster

### Bootstrap / final configProof cycle

There is an intentional dependency cycle: the Forge script needs a valid `configProof.hex`
(because it calls `completeChannel` → `QBFTVerifier.verifyConfig`), but the final
`configProof.hex` needs the trust anchor data that's only available after the Forge script
deploys contracts. The script breaks this cycle by:

1. Writing a **bootstrap** `configProof.hex` with placeholder zeros in the trust anchor
   (valid for `verifyConfig` seal verification but not for later `verifyBundle` codeHash checks)
2. Running the Forge script against that bootstrap file
3. Overwriting `configProof.hex` with the **final** version using the real trust anchor

### Legacy: `generate-configproof.js`

`generate-configproof.js` still exists for reference but is no longer required as a
separate step — `generate-fixture.js` now incorporates the same logic at the end.
