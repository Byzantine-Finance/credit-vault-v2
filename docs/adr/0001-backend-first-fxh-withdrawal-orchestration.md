# ADR 0001: Backend-First FXH Withdrawal Orchestration

- **Status:** Proposed
- **Date:** 2026-07-14
- **Decision owners:** Vault, FXH, API, Product, Security, and Operations maintainers
- **Scope:** EUR vault withdrawals that cannot be satisfied immediately by the configured liquidity adapter

## Context

`VaultV2` serves ordinary ERC-4626 withdrawals synchronously. Its exit path uses idle EURC first and then asks the configured liquidity adapter to deallocate the shortfall. If the adapter cannot provide enough idle EURC, the transaction reverts.

`ByzantineEurVaultAdapter` already provides the asynchronous path needed to recover liquidity from the FX hedge vault:

1. its `adapterCurator` calls `requestWithdraw`;
2. the adapter creates or reuses an `EurVaultPosition` for the active FXH batch;
3. the position requests withdrawal from `ByzantinePrimeEURVault`;
4. FXH settlement completes through its keeper-driven daily net transfer process;
5. `sweepSettled` returns realized EURC to the FXH adapter;
6. unless the FXH adapter is itself the configured `liquidityAdapter`, an authorized `VaultV2` allocator or sentinel must call `VaultV2.deallocate` for the FXH adapter to pull that EURC into parent-vault idle; and
7. only then can a later standard `VaultV2` exit consume the returned EURC.

The current customer experience exposes the synchronous failure. The desired experience is to preserve the normal fast withdrawal path and coordinate the asynchronous path when liquidity is unavailable.

The first proposed architecture replaced all exits with a new on-chain share escrow, reservation queue, and exclusive withdrawal gateway. That architecture would provide stronger fairness and reservation guarantees, but it would also:

- change standard ERC-4626 withdrawal behavior and integrations;
- add calls, transfers, storage writes, and gas to every withdrawal;
- couple queue accounting to `VaultV2`, adapter positions, FXH batch settlement, allocator actions, and haircut behavior;
- require a protocol migration, role changes, and a dedicated audit; and
- solve concurrency and fairness requirements that have not yet been demonstrated by production evidence.

The July 8 product discussion described a backend queue rather than a replacement withdrawal protocol. We therefore need the smallest reversible implementation that tests the actual operational assumptions without imposing a hot-path regression.

## Decision

Start with a **bounded backend-first canary**. Do not modify `VaultV2`, `ByzantineEurVaultAdapter`, `EurVaultPosition`, or `ByzantinePrimeEURVault` for v1.

The canary will:

1. preserve the existing immediate-withdrawal path unchanged;
2. enqueue only a positively identified, allowlisted liquidity-shortfall revert from simulation; all gate, authorization, balance, allowance, deadline, and unknown failures remain on the normal failure path;
3. persist the exact customer-authorized withdrawal transaction and a durable queue record;
4. permit at most one active queued withdrawal per vault and chain;
5. request a bounded number of bpEUR shares from the FXH adapter through the approved `adapterCurator` custody path;
6. derive progress from contract state and receipts rather than a fixed delay;
7. observe or invoke `sweepSettled` after the FXH position settles, using a funded and monitored sender when invocation is required;
8. unless the FXH adapter is the configured `liquidityAdapter`, have an approved allocator or sentinel call `VaultV2.deallocate` for that adapter to move the realized EURC into parent-vault idle;
9. verify the actual parent-vault idle EURC produced by that deallocation;
10. re-simulate the exact customer transaction immediately before broadcast;
11. broadcast it at most once when simulation succeeds; and
12. otherwise enter an explicit terminal or operator-review state.

This is **best-effort orchestration**, not an on-chain reservation system. It does not guarantee FIFO fairness, exclusive access to returned liquidity, a fixed settlement time, or successful execution of a transaction whose state has changed while queued.

A contract-enforced share escrow and reservation queue remains the escalation design. It is not approved for implementation until canary evidence or an explicit product/risk requirement demonstrates that the additional guarantees justify the protocol cost.

## Performance Principle

The common liquid-withdrawal path must not pay for the exceptional illiquid path.

For v1:

- no new contract call, token transfer, storage write, or gas cost is added to an immediately executable withdrawal;
- no new polling or database work occurs for a completed immediate withdrawal beyond existing transaction tracking;
- all durable queue and reconciliation work is isolated to the insufficient-liquidity branch; and
- polling must be bounded and back off while FXH settlement is pending.

## Locked v1 Decisions

### One active request per vault and chain

The canary will not solve concurrent fairness or aggregation. If a queued request is active, another illiquid withdrawal is rejected with a clear retry-later status rather than silently joining an unreserved queue.

This makes ordering deterministic and bounds operational exposure while preserving evidence about attempted overlap.

### Customer authorization remains customer-owned

The API may retain and later broadcast an exact transaction already authorized by the customer. It must not create or alter the customer signature.

Before implementation, a controlled spike must prove that the Atlas/Turnkey transaction remains valid for the maximum intended queue duration. At minimum, the spike must test changes to:

- nonce;
- vault-share balance and allowance;
- transaction deadline or sponsorship validity;
- receiver eligibility and gates;
- vault configuration;
- liquidity and share price; and
- replay behavior after broadcast.

If delayed validity cannot be established safely, v1 falls back to preparing liquidity and asking the customer to re-sign. It does not add contract escrow merely to preserve one-click completion.

### Protocol operational authority is separate from customer signing

`ByzantineEurVaultAdapter.requestWithdraw` is restricted to `adapterCurator`. Exercising this protocol role is not authority to sign a customer withdrawal, but its custody still requires explicit security approval.

The initial canary uses the currently approved human-authorized protocol custody path. An unattended API-held or Byzantine-held signing key is not implicitly approved by this ADR. Automating the curator transaction requires a separate signer-custody decision and must reconcile with the API's non-custodial signing guardrail.

If automation is later approved, the signer must be constrained as narrowly as the custody platform permits by chain, contract, function, and operational limits. A plaintext private key in application environment configuration is prohibited.

### FXH unwind and parent-vault deallocation are distinct operations

`requestWithdraw` is denominated in bpEUR shares, not expected EURC. It can request no more than the bpEUR balance already held by `ByzantineEurVaultAdapter`, and the eventual EURC can be lower after FXH settlement. Sizing must therefore record requested bpEUR shares and reconcile the realized EURC rather than treating the initial conversion as guaranteed.

A settled position leaves EURC on `ByzantineEurVaultAdapter`. If another adapter such as Aave is configured as the parent vault's `liquidityAdapter`, the queued customer exit cannot consume that EURC directly. An approved allocator or sentinel must call:

```solidity
VaultV2.deallocate(address(byzantineEurVaultAdapter), "", realizedAssets)
```

The call sweeps settled positions inside the adapter and transfers the requested idle EURC into `VaultV2`. The target deployment manifest must establish the actual `liquidityAdapter`, FXH adapter, allocator/sentinel custody, and deallocation path; the backend must not infer them from source defaults.

This deallocation authority is a separate protocol role from both customer signing and `adapterCurator`. Human authorization is used in the initial canary unless a later custody decision explicitly approves constrained automation.

### No fixed settlement SLA

FXH settlement is keeper-driven and can be partial, delayed, or zero. “Approximately 24 hours” is an operational expectation, not a contract guarantee. Customer and operator status must reflect observed chain state and pending age without promising a fixed completion time.

### Explicit states and bounded retries

The durable queue must distinguish at least:

```text
queued
→ unwind_authorization_required
→ unwind_submitted
→ awaiting_fxh_settlement
→ settlement_swept
→ vault_deallocation_authorization_required
→ vault_deallocation_submitted
→ vault_idle_confirmed
→ ready_to_broadcast
→ broadcast
→ confirmed
```

Terminal or intervention states must include:

```text
needs_resign
liquidity_conflict
cancelled
expired
operator_review
failed
```

No state may retry indefinitely. Every transaction submission must have an idempotency key, recorded hash/nonce, bounded attempt count, receipt reconciliation, and an operator-visible reason for stopping.

### No rebalancing in v1

Restoring target allocations after an FXH unwind is a separate risk and strategy decision. It is explicitly out of scope for this ADR.

## Required Phase 0 Evidence

This ADR remains `Proposed` until a controlled cross-repository integration test proves the following sequence:

```text
simulate customer withdrawal
→ positively identify the approved liquidity-shortfall revert
→ persist the exact authorized transaction
→ submit a bpEUR-share-bounded adapter requestWithdraw through approved custody
→ execute/finalize controlled FXH settlement
→ sweepSettled using a funded sender when needed
→ observe actual adapter EURC
→ submit authorized VaultV2.deallocate for the FXH adapter when it is not the configured liquidity adapter
→ observe actual parent-vault idle EURC
→ re-simulate the unchanged customer transaction
→ broadcast once
→ reconcile the receipt
```

The test must also demonstrate deterministic handling of:

- a changed nonce;
- moved or insufficient vault shares;
- invalidated transaction authorization or sponsorship;
- a partial or zero FXH settlement;
- a second attempted illiquid request while one is active;
- another withdrawal consuming returned liquidity before broadcast;
- duplicate worker execution and duplicate chain events;
- process restart while each state is active;
- an FXH batch that remains pending beyond the expected interval;
- an unknown or non-liquidity simulation revert, which must never enqueue;
- a requested unwind larger than the adapter's bpEUR balance;
- a deployment where Aave is the configured liquidity adapter and FXH EURC requires explicit authorized deallocation;
- failure or delay of the allocator/sentinel deallocation step;
- a funded sweep sender that is unavailable or underfunded; and
- a large live-position set that makes sweep/deallocation gas behavior unsafe.

The target chain, deployed addresses, source revisions, roles, gates, token decimals, finality policy, and signer custody must be recorded before the test is treated as production evidence.

## What v1 Guarantees

- The ordinary withdrawal path remains unchanged.
- A recognized liquidity shortfall becomes an observable durable workflow rather than an opaque revert.
- The customer-authorized transaction is not modified by the API.
- FXH unwind and settlement progress are reconciled from chain evidence.
- Submission is idempotent and bounded.
- Failure and intervention states are explicit.
- Canary exposure is bounded by cohort, notional, active-request count, retry count, and pending age.

## What v1 Does Not Guarantee

- Returned EURC is not reserved on chain for the queued transaction.
- A competing direct withdrawal may consume liquidity first.
- The customer transaction may become stale while queued.
- The request has no guaranteed completion time.
- Queue fairness beyond one active request is not provided.
- FXH payout or parent-vault asset value is not guaranteed.

These limitations must be present in product and operational language. The system must not describe a queued request as guaranteed or completed before the customer withdrawal is confirmed on chain.

## Stop and Escalation Conditions

Stop the canary and review the contract-enforced queue design if any of the following occurs:

1. returned liquidity is consumed by a competing exit before the queued transaction can broadcast;
2. product demand requires more than one concurrent queued withdrawal per vault;
3. delayed transactions require re-signing at an unacceptable rate;
4. queued notional exceeds the approved operational risk cap;
5. integrators require a composable on-chain claim or transferable withdrawal receipt;
6. product or risk requires guaranteed FIFO/pro-rata reservation; or
7. manual protocol authorization becomes an operational bottleneck and no acceptable constrained-signer design is approved.

A contract-first follow-up must be a separate ADR. It must define custody, cancellation, partial settlement, allocator interaction, reservation accounting, migration, standard-interface compatibility, and emergency behavior before implementation.

## Options Considered

### Option A: Contract-enforced escrow and reservation immediately

**Deferred.** This provides the strongest customer entitlement and fairness guarantees, but it changes the public protocol before evidence establishes that those guarantees are required. It also makes the normal liquid path more expensive and introduces new accounting and migration risk.

### Option B: Bounded backend-first orchestration

**Selected.** It directly addresses the current UX failure, preserves the existing hot path, uses the asynchronous mechanism already present in the contracts, and produces evidence for or against later protocol changes.

### Option C: Prepare liquidity, then ask the customer to sign again

**Fallback.** This is simpler and avoids retaining a delayed signed transaction, but it requires the customer to return after settlement. It becomes v1 if the Phase 0 delayed-validity test fails.

### Option D: Keep returning the synchronous liquidity error

**Rejected.** This preserves technical simplicity but does not address the product requirement or create an operational path for restoring liquidity.

## Consequences

### Positive

- No contract deployment, migration, or audit is required for the canary.
- The common withdrawal path keeps its current gas and latency profile.
- The implementation is reversible and can be disabled without moving customer shares.
- Real collision, concurrency, signer, settlement-time, and stale-transaction data will inform any later contract design.
- The contract boundary remains standard for existing integrations.

### Negative

- The canary cannot reserve returned liquidity on chain.
- Operations participate in adapter-curator and parent-vault deallocation authorization until separate automation decisions are approved.
- Only one active illiquid request is supported per vault and chain.
- Some customers may need to re-sign or retry.
- The backend requires durable queue storage, reconciliation, monitoring, and runbooks.

### Neutral

- FXH keeper and settlement trust assumptions are unchanged.
- Existing allocator and adapter behavior are unchanged.
- Rebalancing remains a separate initiative.

## Acceptance and Review

Before changing this ADR to `Accepted`, reviewers must approve:

- the exact allowlisted liquidity-shortfall revert selector and simulation call context;
- proof that all other simulation failures cannot enqueue;
- delayed transaction validity or the re-sign fallback;
- queue and retry limits;
- customer-facing non-guarantees;
- the approved adapter-curator custody path;
- the deployed liquidity adapter and the authorized FXH-adapter-to-parent-vault deallocation path;
- allocator/sentinel and sweep-sender custody, funding, and monitoring;
- bpEUR unwind-sizing bounds and realized-EURC reconciliation;
- deployment metadata and finality policy;
- controlled integration-test evidence; and
- operational ownership and stop authority for the canary.

## References

- [`src/VaultV2.sol`](../../src/VaultV2.sol)
- [`src/adapters/ByzantineEurVaultAdapter.sol`](../../src/adapters/ByzantineEurVaultAdapter.sol)
- [`src/adapters/EurVaultPosition.sol`](../../src/adapters/EurVaultPosition.sol)
- [`Byzantine-Finance/fx-hedge-contract`](https://github.com/Byzantine-Finance/fx-hedge-contract)
- [`Byzantine-Finance/byzantine-api`](https://github.com/Byzantine-Finance/byzantine-api)
- [`byzantine-api/docs/adr/0002-standing-integrator-delegated-authority.md`](https://github.com/Byzantine-Finance/byzantine-api/blob/dev/docs/adr/0002-standing-integrator-delegated-authority.md)
- Internal product discussion, 2026-07-08
