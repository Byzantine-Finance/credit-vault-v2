# ADR 0001: Backend-First FXH Withdrawal Orchestration

- **Status:** Proposed
- **Date:** 2026-07-14
- **Owners:** Vault, FXH, API, Product, Security, and Operations maintainers
- **Scope:** EUR vault withdrawals that exceed immediately available liquidity

## Context

`VaultV2` serves withdrawals synchronously. It uses idle EURC first, then asks its configured liquidity adapter for the shortfall. If the adapter cannot provide enough EURC, the transaction reverts.

The July 8 discussion described Aave as the liquid adapter holding roughly 10% of vault assets and the FXH adapter holding roughly 85%. These are deployment observations, not source defaults. We must verify the live configuration before implementation.

Liquidity can return from FXH through the existing contracts:

1. `adapterCurator` calls `ByzantineEurVaultAdapter.requestWithdraw` with bpEUR shares.
2. FXH processes the request through its keeper-driven daily net transfer.
3. `sweepSettled` moves realized EURC to `ByzantineEurVaultAdapter`.
4. If FXH is not the configured liquidity adapter, an authorized allocator or sentinel calls `VaultV2.deallocate` to move the EURC into parent-vault idle.
5. The original customer withdrawal can then execute.

The customer should see a queued withdrawal instead of a failed transaction. The common liquid-withdrawal path should stay unchanged.

## Decision

Start with a bounded backend canary. Do not change `VaultV2`, `ByzantineEurVaultAdapter`, `EurVaultPosition`, or `ByzantinePrimeEURVault` for v1.

```text
simulate the customer withdrawal
├─ success → use the existing immediate path
└─ approved liquidity-shortfall revert
   → persist the exact customer-authorized transaction
   → return a queue ID and notify operations
   → request a bounded FXH withdrawal
   → wait for observed FXH settlement
   → sweep the realized EURC
   → deallocate it into VaultV2 when required
   → verify parent-vault idle EURC
   → re-simulate the unchanged customer transaction
   → broadcast once or stop in an explicit failure state
```

Only an allowlisted liquidity-shortfall revert may enter the queue. Gate, balance, allowance, deadline, authorization, and unknown failures remain normal failures.

The canary supports one active queued withdrawal per vault and chain. A second illiquid request receives a retry-later response.

This is best-effort orchestration. It does not reserve liquidity on chain or guarantee completion, ordering, payout, or settlement time.

## Why start here

- Immediate withdrawals keep their current gas and latency profile.
- The implementation is reversible and uses the contracts' existing async withdrawal path.
- We have no production evidence yet that concurrent fairness or on-chain reservation is required.

A contract escrow and reservation queue remains an escalation option. It is not approved by this ADR.

## V1 guardrails

### Customer authorization

The API may store and later broadcast a transaction already authorized by the customer. It must not create or alter the customer's signature, amount, receiver, or destination.

Before implementation, a controlled test must prove that the Atlas/Turnkey transaction remains valid for the intended delay. Test at least nonce changes, moved shares or revoked allowance, deadlines or sponsorship expiry, receiver gates, vault configuration, share-price changes, and replay.

If delayed authorization is unsafe, the fallback is simple: prepare liquidity, notify the customer, and ask them to sign again.

### Protocol authority

`requestWithdraw` requires `adapterCurator`. Moving settled EURC from the FXH adapter into `VaultV2` may also require an allocator or sentinel.

The first canary uses the currently approved human-authorized custody path for these calls. This ADR does not approve an unattended API-held key. Any later automation needs a separate custody decision and must comply with the API's non-custodial signing rules. Plaintext production keys in application configuration are prohibited.

### Settlement and accounting

`requestWithdraw` is denominated in bpEUR shares. It cannot request more bpEUR than the adapter holds, and final EURC may be lower after FXH settlement. Record requested shares and reconcile actual EURC.

When Aave is the configured liquidity adapter, settled EURC on the FXH adapter is not yet available to the customer withdrawal. An allocator or sentinel must call:

```solidity
VaultV2.deallocate(address(byzantineEurVaultAdapter), "", realizedAssets)
```

The deployment manifest must identify the actual adapters, roles, addresses, token decimals, and deallocation path.

FXH settlement is keeper-driven and may be late, partial, or zero. “Approximately 24 hours” is an expectation, not an SLA.

### Queue state and retries

The durable state should be no more detailed than operations need:

```text
queued
→ unwind_required
→ awaiting_fxh_settlement
→ deallocation_required
→ ready_to_broadcast
→ broadcast
→ confirmed
```

Terminal states: `needs_resign`, `liquidity_conflict`, `cancelled`, `expired`, `operator_review`, and `failed`.

No state retries indefinitely. Record idempotency keys, hashes, nonces, attempt counts, receipts, and the reason work stopped.

### Customer and operator visibility

A queued response includes a stable queue ID and queryable status. The customer-facing response must not expose the internal simulation revert.

The original transaction remains authoritative for wallet or bank/off-ramp destination. For bank withdrawals, the queue hands off to the existing off-ramp lifecycle after the on-chain withdrawal confirms.

Do not describe a queued request as guaranteed or complete before the customer withdrawal confirms. FXH liquidity settlement and downstream bank settlement are separate statuses.

Telegram notifications are required when a request queues, needs human action, exceeds its pending-time threshold, needs re-signing or review, and reaches a terminal state. Notifications are observational; database and chain state remain authoritative.

The canary is automatic from the customer's perspective only when the stored authorization remains valid. Privileged protocol calls remain human-authorized until a separate decision approves automation.

### Rebalancing

Post-withdrawal rebalancing is out of scope. It requires a separate strategy and risk decision.

## Transcript traceability

| July 8 concern | Decision |
|---|---|
| Small withdrawals should remain immediate | Keep the current liquid path unchanged. |
| Large withdrawals should queue instead of reverting | Convert only the approved simulation failure into a queue ID and status. |
| Store the signed withdrawal | Persist the exact customer-authorized transaction; prove delayed validity first. |
| Notify the team | Send Telegram notifications for queue, intervention, and terminal events. |
| Request FXH liquidity and wait roughly 24 hours | Use `adapterCurator`, then follow chain state rather than a fixed timer. |
| Complete to a wallet or bank account | Preserve the original receiver/off-ramp destination and broadcast once liquidity is available. |
| Put the curator key in the API environment | Rejected. Start with approved human custody; decide constrained automation separately. |
| Consider rebalancing later | Deferred. |
| Propose before implementation | Keep this ADR `Proposed` until the evidence below is reviewed. |

## Evidence required before acceptance

A controlled cross-repository test must prove:

```text
approved simulation failure
→ persisted customer transaction
→ bounded requestWithdraw
→ FXH settlement
→ sweepSettled
→ authorized VaultV2.deallocate when required
→ verified parent-vault idle EURC
→ successful re-simulation
→ one broadcast and reconciled receipt
```

It must also cover:

- stale nonce, moved shares or revoked allowance, expired authorization, and replay;
- partial or zero settlement;
- unknown simulation failures, which must never queue;
- a second illiquid request while one is active;
- another withdrawal consuming returned EURC;
- duplicate workers or events and process restart;
- unavailable protocol authorization or sweep gas; and
- unsafe sweep/deallocation gas as the position set grows.

Record the target chain, source revisions, deployed addresses, roles, gates, decimals, finality policy, and signer custody with the test evidence.

## Limits and escalation

V1 does not guarantee:

- on-chain reservation of returned EURC;
- protection from a competing direct withdrawal;
- a still-valid customer transaction after the wait;
- a completion deadline;
- fairness beyond one active request;
- a fixed EURC payout; or
- unattended protocol operations.

Stop the canary and reconsider contract escrow or signer automation if:

- returned liquidity is consumed before broadcast;
- more than one concurrent request is needed;
- re-signing is too frequent;
- queued value exceeds the approved risk cap;
- product requires guaranteed reservation or a composable claim; or
- manual protocol authorization becomes the bottleneck.

## Alternatives

- **Contract escrow now — deferred.** Stronger reservation and fairness, but changes ERC-4626 behavior, adds gas to every withdrawal, and requires migration and audit.
- **Backend canary — selected.** Preserves the hot path and tests the existing async mechanism with bounded exposure.
- **Prepare liquidity, then ask the customer to re-sign — fallback.** Use this if delayed transaction validity cannot be proven.
- **Keep returning the synchronous error — rejected.** It does not solve the customer or operational problem.

## Acceptance

Change this ADR to `Accepted` only after reviewers approve:

- the exact liquidity-shortfall revert classification;
- delayed authorization or the re-sign fallback;
- queue, retry, pending-time, and value limits;
- curator, allocator/sentinel, and sweep custody;
- deployment metadata and bpEUR-to-realized-EURC accounting;
- customer status, destination handoff, Telegram escalation, and stated non-guarantees; and
- the controlled integration-test evidence and operational owner.

## References

- [`src/VaultV2.sol`](../../src/VaultV2.sol)
- [`src/adapters/ByzantineEurVaultAdapter.sol`](../../src/adapters/ByzantineEurVaultAdapter.sol)
- [`src/adapters/EurVaultPosition.sol`](../../src/adapters/EurVaultPosition.sol)
- [`Byzantine-Finance/fx-hedge-contract`](https://github.com/Byzantine-Finance/fx-hedge-contract)
- [`Byzantine-Finance/byzantine-api`](https://github.com/Byzantine-Finance/byzantine-api)
- [`byzantine-api ADR 0002`](https://github.com/Byzantine-Finance/byzantine-api/blob/dev/docs/adr/0002-standing-integrator-delegated-authority.md)
- Internal product discussion, 2026-07-08