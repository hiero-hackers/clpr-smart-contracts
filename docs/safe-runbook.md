# Safe Multisig Runbook — ClprService Ownership

This runbook covers the Safe multisig that owns `ClprService`. Ownership of the
head contract is transferred to the Safe during deployment (via the
`--transfer-ownership-to-account` flag on `cli.ts`), after which all `onlyOwner`
functions — e.g. `setClprEnabled` — can only be executed by a transaction that
meets the Safe's signing threshold.

> **Fill in every** `<…>` **placeholder below before treating this document as
> authoritative.** The signer identities, threshold, addresses, and emergency
> contact are environment-specific and must reflect the live deployment.

---



## 1. Current configuration


| Field                               | Value                                    |
| ----------------------------------- | ---------------------------------------- |
| Network                             | `<network / chain id, e.g. mainnet / 1>` |
| Safe address (`OWNER_ACCOUNT`)      | `<0x…>`                                  |
| Safe singleton (`SAFE_SINGLETON`)   | `<0x…>`                                  |
| Safe proxy factory (`SAFE_FACTORY`) | `<0x…>`                                  |
| Owned contract (`ClprService`)      | `<0x…>`                                  |
| Threshold                           | `<M>` of `<N>`                           |
| Safe contract version               | `<e.g. v1.5.0>`                          |




### Current signers


| #   | Name / Role     | Address | Key custody                      | Contact             |
| --- | --------------- | ------- | -------------------------------- | ------------------- |
| 1   | `<name / role>` | `<0x…>` | `<hardware wallet / HSM / etc.>` | `<email or handle>` |
| 2   | `<name / role>` | `<0x…>` | `<…>`                            | `<…>`               |
| 3   | `<name / role>` | `<0x…>` | `<…>`                            | `<…>`               |


Add rows to match the actual owner count `<N>`. The address list here MUST match
the owners returned by the Safe's `getOwners()` on-chain — see verification below.

### Verify configuration on-chain

```bash
# List current owners
cast call <OWNER_ACCOUNT> "getOwners()(address[])" --rpc-url <RPC_URL>

# Read current threshold
cast call <OWNER_ACCOUNT> "getThreshold()(uint256)" --rpc-url <RPC_URL>

# Confirm the Safe owns ClprService
cast call <CLPR_SERVICE> "owner()(address)" --rpc-url <RPC_URL>
# → should return <OWNER_ACCOUNT>
```

---



## 2. Signer rotation procedure

Owner changes are themselves `onlyOwner` actions **on the Safe**, so each
rotation is a Safe transaction that must collect `<threshold>` signatures. These
are the standard Safe owner-management functions; they are called *on the Safe
itself*, with the Safe as both target and executor.

Preferred path is the Safe web/UI or Safe CLI, which handles signature
collection. The relevant functions are:


| Action                | Function                                                           |
| --------------------- | ------------------------------------------------------------------ |
| Add a signer          | `addOwnerWithThreshold(address owner, uint256 threshold)`          |
| Remove a signer       | `removeOwner(address prevOwner, address owner, uint256 threshold)` |
| Replace a signer      | `swapOwner(address prevOwner, address oldOwner, address newOwner)` |
| Change threshold only | `changeThreshold(uint256 threshold)`                               |


`prevOwner` is the owner that points to `owner` in the Safe's internal linked
list. To find it, fetch `getOwners()` and use the address immediately preceding
the target; for the first owner in the list, `prevOwner` is the sentinel
`0x0000000000000000000000000000000000000001`.

### To add a signer

1. Agree on the new signer and the resulting threshold out-of-band with the
  current signers.
2. Propose an `addOwnerWithThreshold(<newOwner>, <newThreshold>)` transaction on
  the Safe.
3. Collect `<threshold>` signatures from current signers.
4. Execute. Verify with `getOwners()` and `getThreshold()` (commands above).
5. Update the signer table in §1 of this document and commit it.



### To remove a signer

1. Determine `prevOwner` from the current `getOwners()` ordering.
2. Propose `removeOwner(<prevOwner>, <ownerToRemove>, <newThreshold>)`. Ensure
  the new threshold is still `≥ 1` and `≤` remaining owner count.
3. Collect signatures and execute.
4. Verify on-chain, then update §1 and commit.



### To replace a signer (recommended over remove-then-add)

1. Determine `prevOwner` for the outgoing owner.
2. Propose `swapOwner(<prevOwner>, <oldOwner>, <newOwner>)` — threshold is
  unchanged, so this is a single atomic rotation.
3. Collect signatures and execute.
4. Verify and update §1.

> **Threshold safety:** never reduce the owner set below the threshold, and
> never set the threshold to `0`. Either can permanently lock the Safe. After
> any change, the invariant `1 ≤ threshold ≤ ownerCount` must hold.

---



## 3. Routine owner-only operations

Owner-gated actions on `ClprService` (e.g. the CLPR kill switch) are executed as
Safe transactions whose target is `ClprService` and whose calldata is the
encoded function call. The call reaches `AdminLogic` via delegatecall and runs
against the head's storage, where the owner check sees the Safe.

If your signers use the Safe web UI or Safe CLI, use those — they handle
hashing, ordering and submission for you. The procedure below is the
dependency-free `cast` path, for when the UI is unavailable or a signer is
working from a terminal.

### Signing and executing with `cast`

```bash
SAFE=<OWNER_ACCOUNT>
TARGET=<CLPR_SERVICE>
RPC=<RPC_URL>
ZERO=0x0000000000000000000000000000000000000000

# 1. Encode the inner call. Example: the CLPR kill switch.
DATA=$(cast calldata "setClprEnabled(bool)" false)

# 2. Read the Safe's current nonce — it is part of the signed payload, so a
#    stale value produces signatures that will not validate.
NONCE=$(cast call $SAFE "nonce()(uint256)" --rpc-url $RPC)

# 3. Compute the Safe transaction hash that every signer must sign.
#    Keep safeTxGas, baseGas and gasPrice at 0 — see "Keep the gas fields zero".
SAFE_TX_HASH=$(cast call $SAFE \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  $TARGET 0 $DATA 0 0 0 0 $ZERO $ZERO $NONCE --rpc-url $RPC)
```

Distribute `$SAFE_TX_HASH` to the signers. Each signer independently produces a
signature over it — `--no-hash` is required because the value is already a
32-byte digest and must not be hashed again:

```bash
# 4. Run once per signer, on that signer's own machine. Signers whose key
#     custody is a hardware wallet (see §1) should use --ledger / --trezor
#     instead of --private-key; a raw key should never leave its custody.
cast wallet sign --no-hash $SAFE_TX_HASH --ledger
```

Only the 65-byte signature output needs to be shared. Collect all
`<threshold>` of them on whichever machine will broadcast.

```bash
# 5. Concatenate the collected signatures in ASCENDING signer-address order,
#    keeping one leading "0x" and stripping it from every subsequent signature.
#    Order matters even when every signature is individually valid.
SIGS=0x<sig of lowest-addressed signer><sig of next><…>

# 6. Dry-run first — this simulates via eth_call and broadcasts nothing.
cast call $SAFE \
  "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)" \
  $TARGET 0 $DATA 0 0 0 0 $ZERO $ZERO $SIGS --from <any address> --rpc-url $RPC

# 7. Execute. Any funded address may broadcast — the executor does NOT need to
#    be a signer, and broadcasting is not itself an approval.
cast send $SAFE \
  "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)" \
  $TARGET 0 $DATA 0 0 0 0 $ZERO $ZERO $SIGS --private-key <broadcaster key> --rpc-url $RPC
```

Each execution consumes the Safe nonce. If you need to run a second owner-only
call, re-read the nonce at step 2 and collect fresh signatures — signatures are
not reusable across nonces.

### Keep the gas fields zero

`safeTxGas`, `baseGas` and `gasPrice` exist for relayer-paid transactions. Leave
all three at `0` when signing by hand, because they change what happens when the
inner call reverts:

- With `safeTxGas = 0` **and** `gasPrice = 0`, a failing inner call bubbles up
and the whole transaction reverts. You get a loud, unambiguous failure.
- With a non-zero `safeTxGas`, a failing inner call does **not** revert the
transaction. It lands with `status: 1 (success)` and the Safe emits
`ExecutionFailure` instead of `ExecutionSuccess`. The owner-only action never
took effect even though the receipt looks successful.

Either way, never treat receipt status as proof — verify as below.

### Verify the execution

```bash
cast receipt <TX_HASH> --rpc-url $RPC
```

`cast receipt` prints raw, undecoded logs, so match on topic hashes:


| Topic0                                                               | Event              | Meaning                                                                                          |
| -------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------ |
| `0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e` | `ExecutionSuccess` | The inner call ran and succeeded.                                                                |
| `0x23428b18acfb3ea64b08dc0c1d296ea9c09702c09083ca5272e64d115b687d23` | `ExecutionFailure` | The Safe transaction was authorized but the inner call reverted — **the action did not happen.** |


Confirm `ExecutionSuccess` is present, then confirm the *target's* own event also
fired (for the kill switch, `ClprEnabledChanged` — see
`[docs/runbooks/kill-switch.md](runbooks/kill-switch.md)`).

### Common failure codes


| Code    | Cause                                                             |
| ------- | ----------------------------------------------------------------- |
| `GS020` | Fewer than `<threshold>` signatures in the concatenated blob.     |
| `GS026` | Signatures out of ascending-address order, or a non-owner signed. |


---



## 4. Emergency procedures

### Emergency contact

| Role | Name | Channel | Availability |
|------|------|---------|--------------|
| Primary on-call | `<name>` | `<phone / Signal / PagerDuty>` | `<hours / 24x7>` |
| Secondary | `<name>` | `<…>` | `<…>` |
| Security escalation | `<name / team>` | `<…>` | `<…>` |

### If a signer key is compromised

1. **Immediately** convene the remaining trusted signers out-of-band via the
  emergency contacts above.
2. If the kill switch is the right mitigation, propose and execute
  `setClprEnabled(false)` as a Safe transaction (§3) — this requires only the
   normal threshold and does not depend on removing the compromised key first.
3. Rotate out the compromised signer with `swapOwner` (§2). Do this with urgency:
  while the compromised key still counts toward the threshold, an attacker
   holding it reduces the effective security margin.
4. If the number of compromised keys approaches the threshold, treat as a
  critical incident — escalate to security and consider migrating ownership to a
   freshly provisioned Safe.



### If signers are unreachable / threshold cannot be met

If enough signers are permanently unavailable that the threshold can no longer
be reached, the Safe is effectively frozen and ownership actions become
impossible. There is no recovery without a pre-existing recovery module. Record
here any recovery mechanism in place, or explicitly note that none exists:

> Recovery mechanism: `<none / Safe recovery module at 0x… / social recovery / …>`

---

## 5. Change log

| Date | Change | Tx hash | Updated by |
|------|--------|---------|-----------|
| `<YYYY-MM-DD>` | `<e.g. ownership transferred to new owner>` | `<0x…>` | `<name>` |

Keep this table current — every owner or threshold change should add a row.