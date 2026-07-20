# ADR 0001: Backend-First FXH Withdrawal Orchestration

- **Status:** Accepted
- **Date:** 2026-07-14
- **Accepted:** 2026-07-20
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

### Liquidity admission

Queue admission has two distinct checks:

- **Authoritative:** simulate the Atlas inner withdrawal call from the wallet address and enqueue only a positively identified liquidity-shortfall selector from the expected vault call. Validate the Atlas authorization, deadline, and unused nonce separately because the current simulation executes inner calls directly rather than the Atlas envelope.
- **Advisory:** RPC liquidity reads may improve the response shown before signing, but must not decide queue admission until their equation is defined and tested. `AaveStrategy.realAssets()` is the strategy's aToken claim plus idle assets; it is not guaranteed immediately withdrawable Aave liquidity.

Benoit's fake-vault tests must establish stable liquidity and non-liquidity selectors. A production fork must then prove the classification through the deployed VaultV2, Aave strategy, and gates. Matching an error message string alone is not sufficient.

### Customer authorization

All Byzantine wallets use the EIP-7702 Atlas delegation. Atlas supports sponsored execution, a deadline, and replay protection after a successful call; it does not force withdrawals through the Byzantine API.

The API may store and later broadcast an exact transaction already authorized by the customer. It must not create or alter the customer's signature, amount, receiver, or destination. A failed Atlas execution rolls back Atlas nonce consumption, so the authorization may remain usable. The current API uses an effectively unbounded deadline; the canary must use a bounded withdrawal deadline or an explicit revocation mechanism before delayed automatic broadcast is approved.

A controlled test must cover moved shares or revoked allowance, nonce reuse, deadline and sponsorship expiry, receiver gates, vault configuration, share-price changes, failed execution, and replay.

If delayed authorization is unsafe, the fallback is simple: prepare liquidity, notify the customer, and ask them to sign again.

### Protocol authority

`requestWithdraw` requires `adapterCurator`. Moving settled EURC from the FXH adapter into `VaultV2` may also require an allocator or sentinel.

The first canary uses the currently approved human-authorized custody path for these calls. This ADR does not approve an unattended API-held key. Any later automation needs a separate custody decision and must comply with the API's non-custodial signing rules. Plaintext production keys in application configuration are prohibited.

Alex will assess whether Hypernative can cover withdrawals submitted outside the Byzantine API. Hypernative is not selected by this ADR. Before it can trigger `requestWithdraw`, the design must define observation coverage, curator custody, sizing, idempotency, caps, duplicate suppression, and resistance to deliberately failing withdrawals. A failed direct-wallet transaction is not by itself a durable API queue record or proof that the customer still wants an unwind. Without reusable customer authorization, Hypernative could only replenish liquidity; the customer would still have to retry the withdrawal.

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

### Withdrawal limits and queued amounts

`get_vault_v2_max_withdrawal` currently calculates a wallet's asset entitlement from its vault shares. Subtracting the global queued total from that value would mix user ownership with system liquidity and understate unrelated users' entitlement.

Keep these concepts separate:

- **wallet entitlement:** the existing maximum based on the wallet's shares;
- **API-requestable amount:** wallet entitlement less that wallet's active queued commitment; and
- **remaining queue capacity:** the canary risk cap less all active queued commitments.

The durable one-active-request rule is the admission lock. These API values are advisory and cannot prevent a direct wallet transaction from moving shares or consuming liquidity; final simulation and chain reconciliation remain required.

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
| Propose before implementation | Decision accepted; canary rollout remains gated by the evidence below. |

## Open research and owners

- **Benoit — revert classification:** deploy controlled fake vaults to exercise known failures, then repeat the full path on a pinned fork using official deployment addresses. Whitelist the test wallet and receiver before classifying any revert; a gate failure is not a liquidity failure.
- **Alex — Hypernative/API split:** determine whether Hypernative can observe API-bypassing attempts and safely trigger a bounded unwind. Document custody, deduplication, griefing controls, and which system owns each state transition.
- **Vault/API — Aave estimate:** define and test an advisory available-liquidity equation. It must account for vault idle, strategy idle, the adapter's aToken claim, actual Aave reserve liquidity, and conditions that can still make `pool.withdraw` revert.

Until these are resolved, simulation remains the only queue-admission authority and the canary covers API-observed requests only.

## Evidence required before canary rollout

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
- unavailable protocol authorization or sweep gas;
- unsafe sweep/deallocation gas as the position set grows;
- the same liquidity classification against fake vaults and a pinned production fork;
- a whitelisted fork wallet and receiver, plus negative gate tests;
- Atlas authorization with a bounded deadline or a tested revocation path;
- separate wallet-entitlement, per-wallet queued-commitment, and global queue-capacity calculations; and
- a direct-wallet attempt that bypasses the API, with the documented v1 response.

Record the target chain, source revisions, deployed addresses, roles, gates, decimals, finality policy, and signer custody with the test evidence.

## Limits and escalation

V1 does not guarantee:

- on-chain reservation of returned EURC;
- protection from a competing direct withdrawal;
- a still-valid customer transaction after the wait;
- a completion deadline;
- fairness beyond one active request;
- a fixed EURC payout;
- unattended protocol operations; or
- coverage of withdrawals submitted outside the Byzantine API.

Stop the canary and reconsider contract escrow or signer automation if:

- returned liquidity is consumed before broadcast;
- more than one concurrent request is needed;
- re-signing is too frequent;
- queued value exceeds the approved risk cap;
- product requires guaranteed reservation or a composable claim;
- manual protocol authorization becomes the bottleneck;
- API-bypassing withdrawal attempts are frequent enough to invalidate the canary; or
- Hypernative automation cannot meet the approved custody, deduplication, sizing, and grief-resistance constraints.

## Alternatives

- **Contract escrow now — deferred.** Stronger reservation and fairness, but changes ERC-4626 behavior, adds gas to every withdrawal, and requires migration and audit.
- **Backend canary — selected.** Preserves the hot path and tests the existing async mechanism with bounded exposure.
- **Prepare liquidity, then ask the customer to re-sign — fallback.** Use this if delayed transaction validity cannot be proven.
- **Keep returning the synchronous error — rejected.** It does not solve the customer or operational problem.

## Canary rollout gates

Do not enable the canary until reviewers approve:

- the exact liquidity-shortfall revert classification;
- delayed authorization or the re-sign fallback;
- queue, retry, pending-time, and value limits;
- curator, allocator/sentinel, and sweep custody;
- deployment metadata and bpEUR-to-realized-EURC accounting;
- customer status, destination handoff, Telegram escalation, and stated non-guarantees;
- the controlled integration-test evidence and operational owner;
- the separation between wallet entitlement, per-wallet queued commitment, and global queue capacity;
- the fake-vault and whitelisted-fork revert-classification evidence;
- a bounded Atlas deadline or revocation mechanism; and
- the explicit API-only coverage decision or an approved Hypernative design.

## References

- [`src/VaultV2.sol`](../../src/VaultV2.sol)
- [`src/adapters/ByzantineEurVaultAdapter.sol`](../../src/adapters/ByzantineEurVaultAdapter.sol)
- [`src/adapters/EurVaultPosition.sol`](../../src/adapters/EurVaultPosition.sol)
- [`src/adapters/AaveStrategy.sol`](../../src/adapters/AaveStrategy.sol)
- [`Byzantine-Finance/fx-hedge-contract`](https://github.com/Byzantine-Finance/fx-hedge-contract)
- [`Byzantine-Finance/byzantine-api`](https://github.com/Byzantine-Finance/byzantine-api)
- [`byzantine-api ADR 0002`](https://github.com/Byzantine-Finance/byzantine-api/blob/dev/docs/adr/0002-standing-integrator-delegated-authority.md)
- [`Byzantine-Finance/Atlas`](https://github.com/Byzantine-Finance/Atlas/blob/main/src/Atlas.sol)
- [Byzantine Curator deployment view](https://curator.byzantine.fi/vault/0x2f99e35ea811f3cc230b26dff817604b5d4b6e38?tab=adapters&adapter=0)
- Internal product discussion, 2026-07-08