// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/// @notice Testing `ByzantineEurVaultAdapter.realAssets()`
/// @dev    `realAssets` is the adapter's source of truth for the parent vault's `accrueInterest` loop.
///         Conceptually it is the sum of four branches:
///           (A) idle EURC on the adapter + EURC claimable on the EUR vault
///           (B) `convertToAssets(bpEUR balance + claimableShares)` - the value of the bpEUR position
///           (C) per-open-batch pending deposit EURC - summed over open EUR-vault batches not yet settled (corrected
/// via the snapshot-delta during partial finalize) 
///           (D) per-open-batch `convertToAssets(pending withdraw shares)` - summed over the same set (same correction)
///
/// @dev ±1-wei tolerances: convertToAssets() floors (rounds down). 
///      A value that is exact in real terms (e.g. SEED) is reconstructed from
///      two independently-floored share→EURC conversions — convertToAssets(a) + convertToAssets(b)
///      can be 1 wei below convertToAssets(a + b). Tolerance only bites when W is not a clean
///      multiple of BPEUR_PER_EURC.
contract ByzantineEurVaultRealAssetsTest is ByzantineEurVaultIntegrationTest {
    using MathLib for uint256;

    /* ------------------------------------------------------------------ */
    /*  Constants used by the normal-flow tests                           */
    /* ------------------------------------------------------------------ */

    /// @dev 100 EURC (6 decimals). Picked for clean arithmetic in assertions.
    uint256 internal constant ASSETS_100 = 100e6;

    /// @dev 250 EURC. Used for multi-allocate tests.
    uint256 internal constant ASSETS_250 = 250e6;

    /* ------------------------------------------------------------------ */
    /*  Branch (A): idle EURC + claimable EURC                            */
    /* ------------------------------------------------------------------ */

    /// @notice Fresh adapter, no state set up - realAssets must be zero.
    function testRealAssetsZeroOnFreshAdapter() public view {
        assertEq(adapter.realAssets(), 0, "fresh adapter should report 0 realAssets");
    }

    /// @notice Idle EURC sitting directly on the adapter is counted by branch (A).
    /// @dev    Uses `deal` to skip a normal flow and isolate the branch
    function testRealAssetsCountsIdleEurc(uint256 amount) public {
        amount = bound(amount, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), amount);

        assertEq(adapter.realAssets(), amount, "idle EURC must be counted via branch (A)");
    }

    /// @notice EURC parked in `claimableEurc[adapter]` after a gate-blocked withdraw settlement is
    ///         counted by branch (A).
    /// @dev    Full deposit -> settle -> requestWithdraw -> settle (gate-blocked) - the withdraw
    ///         payout lands in claimableEurc instead of being transferred directly.
    function testRealAssetsCountsClaimableEurc() public {
        // 1) Deposit + allocate + settle (gate-open: shares end up on the adapter directly).
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAdapterBatch();

        // 2) Burn the shares via requestWithdraw + settle on the gate-blocked path so the EURC payout
        //    sits as claimableEurc instead of being transferred to the adapter.
        uint256 shares = IERC20(address(eurVault)).balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable();

        // Adapter holds nothing idle; the EURC is sitting as claimableEurc on the EUR vault.
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC expected");
        assertEq(eurVault.claimableEurc(address(adapter)), ASSETS_100, "claimable EURC must equal deposit");
        assertEq(adapter.realAssets(), ASSETS_100, "claimable EURC must be counted via branch (A)");
    }

    /* ------------------------------------------------------------------ */
    /*  Branch (B): bpEUR position (balance + claimable shares)           */
    /* ------------------------------------------------------------------ */

    /// @notice After a gate-open settlement, shares are minted directly to the adapter. realAssets must
    ///         count them via `convertToAssets(balanceOf)`.
    function testRealAssetsCountsBpEurBalance() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        _settleAdapterBatch(); // gate-open: shares delivered directly to the adapter

        uint256 shares = IERC20(address(eurVault)).balanceOf(address(adapter));
        assertGt(shares, 0, "shares should be on adapter (gate-open settlement)");
        assertEq(eurVault.claimableShares(address(adapter)), 0, "no claimable shares expected");

        assertEq(adapter.realAssets(), ASSETS_100, "live bpEUR position must be counted via branch (B)");
    }

    /// @notice After a gate-blocked settlement, shares are parked in `claimableShares[adapter]` instead
    ///         of being minted to the adapter. realAssets must include them via `claimableShares`.
    function testRealAssetsCountsClaimableShares() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        _settleAdapterBatchToClaimable(); // gate-blocked: shares parked as claimable on the EUR vault

        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "no live shares (gate-blocked)");
        assertGt(eurVault.claimableShares(address(adapter)), 0, "shares must sit as claimable");
        assertEq(adapter.realAssets(), ASSETS_100, "claimable shares must be counted via branch (B)");
    }

    /* ------------------------------------------------------------------ */
    /*  Branch (C): per-batch pending deposit EURC (pre-DNT settlement)       */
    /* ------------------------------------------------------------------ */

    /// @notice After `vault.allocate` and BEFORE any DNT settlement, the EURC sits in the EUR vault but
    ///         no shares have been minted yet. The whole value must be tracked via the pending-deposit
    ///         branch (C).
    function testRealAssetsCountsPendingDepositBeforeSettlement() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        // No DNT yet: adapter has no EURC, no shares, only the pending shadow.
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC");
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "no shares yet");
        assertEq(eurVault.claimableShares(address(adapter)), 0, "no claimable shares yet");

        uint256 batchId = adapter.openBatchIds(0);
        (uint128 pendingDep,,,, bool isOpen) = adapter.batchAccounting(batchId);
        assertTrue(isOpen, "batch should be open");
        assertEq(uint256(pendingDep), ASSETS_100, "pending deposit EURC should equal allocated amount");

        assertEq(adapter.realAssets(), ASSETS_100, "pending deposit must be counted via branch (C)");
    }

    /// @notice Multiple allocates in the same (still-idle) batch accumulate into one pending-deposit
    ///         entry. realAssets must equal the sum.
    function testRealAssetsAccumulatesMultiAllocateSameBatch() public {
        vault.deposit(ASSETS_100 + ASSETS_250, address(this));

        vm.startPrank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        vault.allocate(address(adapter), hex"", ASSETS_250);
        vm.stopPrank();

        // Only one batch opened (we never settled in between -> same currentBatchId).
        assertEq(adapter.openBatchIdsLength(), 1, "exactly one open batch");
        uint256 batchId = adapter.openBatchIds(0);
        (uint128 pendingDep,,,,) = adapter.batchAccounting(batchId);
        assertEq(uint256(pendingDep), ASSETS_100 + ASSETS_250, "pending must accumulate both allocates");

        assertEq(adapter.realAssets(), ASSETS_100 + ASSETS_250, "realAssets must equal sum of both allocates");
    }

    /* ------------------------------------------------------------------ */
    /*  Branch (D): per-batch pending withdraw shares (pre-DNT settlement)    */
    /* ------------------------------------------------------------------ */

    /// @notice After `requestWithdraw` burns the adapter's bpEUR but BEFORE the next DNT settlement, the
    ///         position is tracked in `pendingWithdrawShares`. realAssets must value it via
    ///         `convertToAssets`.
    function testRealAssetsCountsPendingWithdrawSharesBeforeSettlement() public {
        // Seed the adapter with bpEUR via a full deposit cycle on the gate-open path.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAdapterBatch();

        // Now burn the shares via requestWithdraw, but do NOT settle yet.
        uint256 shares = IERC20(address(eurVault)).balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Adapter no longer has live shares - they were burned at request time.
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "shares burned at request");
        assertEq(eurVault.claimableEurc(address(adapter)), 0, "no claimable EURC yet");

        // The position is now in the pending-withdraw shadow of the active batch.
        uint256 batchId = adapter.openBatchIds(0);
        (,, uint256 pendingW,,) = adapter.batchAccounting(batchId);
        assertEq(pendingW, shares, "pendingWithdrawShares must equal burned shares");

        // realAssets must value the pending withdraw at the EUR vault's current PPS (= 1 at this point).
        assertEq(adapter.realAssets(), ASSETS_100, "pending withdraw must be counted via branch (D)");
    }

    /* ------------------------------------------------------------------ */
    /*  Multi-depositor / multi-withdrawer flows                          */
    /* ------------------------------------------------------------------ */

    /// @notice With another depositor active in the EUR vault, the adapter's `realAssets` must reflect
    ///         only its OWN position — it must not absorb value contributed by other depositors via the
    ///         shared `totalEurcBacking`.
    /// @dev    Validates that the EUR vault's PPS math (which depends on totalEurcBacking and totalSupply
    ///         shared across all depositors) does not pollute the adapter's per-position accounting in
    ///         `_realAssets`. Assume that `owner` == `receiver`.
    function testRealAssetsIsolatedFromOtherDepositors() public {
        address externalUser = makeAddr("externalUser");
        deal(address(eurc), externalUser, ASSETS_250);
        vm.prank(externalUser);
        eurc.approve(address(eurVault), type(uint256).max);

        // 1) Adapter deposits 100 EURC via the normal allocate flow.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        // 2) External user deposits 250 EURC directly to the EUR vault, naming themselves as receiver
        //    (per the owner == receiver convention).
        vm.prank(externalUser);
        eurVault.requestDeposit(ASSETS_250, externalUser);

        // Settle both tickets in one DNT cycle.
        address[] memory receivers = new address[](2);
        receivers[0] = address(adapter);
        receivers[1] = externalUser;
        eurVault.executeDnt();
        eurVault.processDepositChunk(receivers, type(uint256).max);
        eurVault.processWithdrawChunk(receivers, type(uint256).max);
        eurVault.closeBatch();

        // Adapter's realAssets must equal its own deposit (100 EURC), NOT the total backing (350 EURC).
        assertEq(adapter.realAssets(), ASSETS_100, "adapter realAssets isolated from external depositor");
        // Sanity: each party holds the right share count post-settlement.
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), ASSETS_100 * BPEUR_PER_EURC, "adapter shares");
        assertEq(IERC20(address(eurVault)).balanceOf(externalUser), ASSETS_250 * BPEUR_PER_EURC, "external user shares");
    }

    /// @notice In a SINGLE yielded DNT cycle, an external user enters (deposit) while BOTH the adapter and
    ///         another external holder exit (withdraw). The adapter's `realAssets` must equal its OWN
    ///         seed plus its OWN proportional share of the yield — isolated from the concurrent inflow and
    ///         the co-withdrawer that churn `totalEurcBacking` / `totalSupply` within the same batch.
    function testRealAssetsIsolatedInMixedMultiPartyYieldedBatch() public {
        uint256 YIELD = 100e6; // pushes PPS from 1.0 -> 1.5 over the two seeded positions
        uint256 EXT_DEPOSIT = 60e6; // external entrant in the mixed batch
        uint256 seedShares = ASSETS_100 * BPEUR_PER_EURC;

        address holder = makeAddr("holder"); // co-withdrawer: seeds now, exits in the mixed batch
        address entrant = makeAddr("entrant"); // co-depositor: enters in the mixed batch
        deal(address(eurc), holder, ASSETS_100);
        deal(address(eurc), entrant, EXT_DEPOSIT);
        vm.prank(holder);
        eurc.approve(address(eurVault), type(uint256).max);
        vm.prank(entrant);
        eurc.approve(address(eurVault), type(uint256).max);

        // ---- Batch 1: seed the adapter AND `holder` with 100 EURC of bpEUR each (gate-open) ----
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        vm.prank(holder);
        eurVault.requestDeposit(ASSETS_100, holder);

        address[] memory seeders = new address[](2);
        seeders[0] = address(adapter);
        seeders[1] = holder;
        eurVault.executeDnt();
        eurVault.processDepositChunk(seeders, type(uint256).max);
        eurVault.processWithdrawChunk(seeders, type(uint256).max);
        eurVault.closeBatch();

        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), seedShares, "adapter seeded shares");
        assertEq(IERC20(address(eurVault)).balanceOf(holder), seedShares, "holder seeded shares");
        assertEq(adapter.realAssets(), ASSETS_100, "post-seed adapter realAssets == 100 (PPS 1.0)");

        // ---- Yield: backing 200 -> 300 EURC. PPS = 1.5, so each 100-EURC position is now worth 150 ----
        // `setShareRate` only bumps the backing accounting, so deal the matching EURC into the vault to keep
        // its token balance solvent for the larger (yielded) withdraw payouts settled in Batch 2.
        eurVault.setShareRate(int256(YIELD));
        deal(address(eurc), address(eurVault), eurc.balanceOf(address(eurVault)) + YIELD);
        assertEq(adapter.realAssets(), ASSETS_100 + YIELD / 2, "adapter realAssets reflects its half of the yield");

        // ---- Batch 2 (mixed): entrant deposits; adapter AND holder both request full withdraws ----
        vm.prank(entrant);
        eurVault.requestDeposit(EXT_DEPOSIT, entrant);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(seedShares);
        vm.prank(holder);
        eurVault.requestWithdraw(seedShares, holder, holder);

        address[] memory parties = new address[](3);
        parties[0] = address(adapter);
        parties[1] = holder;
        parties[2] = entrant;
        eurVault.executeDnt();
        eurVault.processDepositChunk(parties, type(uint256).max);
        eurVault.processWithdrawChunk(parties, type(uint256).max);
        eurVault.closeBatch();

        // Adapter exited fully at PPS 1.5: 150 EURC paid out, valued by branch (A) as idle EURC. The
        // concurrent entrant deposit and co-withdrawer exit do NOT leak into the adapter's accounting.
        uint256 adapterExitValue = ASSETS_100 + YIELD / 2; // 150 EURC
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "adapter fully exited (no shares)");
        assertEq(eurc.balanceOf(address(adapter)), adapterExitValue, "adapter received its own 150 EURC payout");
        assertEq(adapter.realAssets(), adapterExitValue, "adapter realAssets == own seed + own yield, isolated");

        // Sanity: holder exited at the same PPS; entrant minted at the post-yield PPS (60 EURC worth).
        assertEq(eurc.balanceOf(holder), adapterExitValue, "co-withdrawer received its own 150 EURC payout");
        assertEq(
            eurVault.convertToAssets(IERC20(address(eurVault)).balanceOf(entrant)),
            EXT_DEPOSIT,
            "entrant minted at post-yield PPS (60 EURC worth)"
        );
    }

    /* ------------------------------------------------------------------- */
    /*  Partial burn before DNT execution                       */
    /* ------------------------------------------------------------------- */

    /// @notice After a *partial* `requestWithdraw` (NormalIdle, no DNT yet), the burned shares are
    ///         still economically outstanding until the next DNT settles them. The EUR vault must
    ///         preserve PPS across this gap, so `realAssets` must remain equal to the original
    ///         deposit — half from the adapter's remaining bpEUR (branch B), half from the queued
    ///         burn (branch D), both valued at the *pre-burn* share price.
    function testRealAssetsStableAcrossPartialBurnBeforeDnt() public {
        // Seed 100 EURC of bpEUR onto the adapter via a full deposit cycle.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAdapterBatch();

        uint256 totalShares = IERC20(address(eurVault)).balanceOf(address(adapter));
        uint256 halfShares = totalShares / 2;
        assertGt(halfShares, 0, "must have a meaningful share count for the partial burn");

        // Snapshot the pre-burn realAssets for sanity.
        uint256 realBefore = adapter.realAssets();
        assertEq(realBefore, ASSETS_100, "pre-burn realAssets == deposit");

        // Burn half of the bpEUR — request queued onto the next batch, but no executeDnt yet.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(halfShares);

        // The adapter's bpEUR position is now split between (B) remaining live shares and (D) queued
        // burn. Both halves are valued at the same pre-burn PPS, so the sum must equal the original
        // deposit (within 1 wei for rounding).
        uint256 realAfter = adapter.realAssets();
        assertApproxEqAbs(realAfter, ASSETS_100, 1, "post-partial-burn realAssets must not inflate");
    }

    /* ------------------------------------------------------------------ */
    /*  Edge case: tickets processed but batch not closed                 */
    /* ------------------------------------------------------------------ */

    /// @notice Test for the snapshot-delta double-counting fix.
    /// @dev    Walk-through of the seven check-points, all asserting `realAssets ≈ SEED + D`:
    ///           0) Seed via a full prior batch -> adapter holds `SEED` worth of bpEUR.
    ///           1) `allocate(D)` opens batch N: snapshot captures `(seedShares, 0)`.
    ///           2) `requestWithdraw(W)` burns W shares; sharesSnapshot decremented to
    ///              `(seedShares − W, 0)`; pendingWithdrawShares = W.
    ///           3) `executeDnt()` flips `DntInProgress`. No tickets processed yet.
    ///           4) `processDepositChunk` settles the adapter's deposit ticket: bpEUR silently minted;
    ///              `pendingDepositEurc` shadow STALE; sharesDelta correction cancels it.
    ///           5) `processWithdrawChunk` settles the withdraw ticket: EURC silently paid to adapter;
    ///              `pendingWithdrawShares` shadow STALE; eurcDelta correction cancels it.
    ///           6) `closeBatch` advances `currentBatchId`; snapshot branch disarms (batchId < closedBelow).
    ///
    ///         A ±1-wei tolerance is used where `W` is not a clean multiple of `BPEUR_PER_EURC` (the
    ///         EUR-vault's withdraw payout rounds down). The parent vault's `totalAssets()` is
    ///         reconciled at the end via `accrueInterest()`.
    function testRealAssetsStableAcrossPartialFinalize(uint256 depositAmount, uint256 withdrawShares) public {
        uint256 SEED = 100e6; // 100 EURC seed in batch 0 — gives the adapter bpEUR to burn for the withdraw
        depositAmount = bound(depositAmount, 1e6, SEED); // [1, 100] EURC for batch N's deposit
        uint256 seedShares = SEED * BPEUR_PER_EURC;
        // At least 1 EURC worth of shares; less than the seed (must leave some bpEUR on the adapter so
        // it can still participate as a holder during the DNT).
        withdrawShares = bound(withdrawShares, BPEUR_PER_EURC, seedShares - 1);
        uint256 expected = SEED + depositAmount;

        // ---- Phase 0: seed the adapter with `SEED` worth of bpEUR via a full prior batch ----
        vault.deposit(SEED, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", SEED);
        _settleAdapterBatch(); // gate-open: shares minted directly to the adapter
        assertEq(adapter.realAssets(), SEED, "phase 0: post-seed realAssets == SEED");
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), seedShares, "phase 0: adapter holds seedShares");

        // ---- Phase 1: allocate(D) opens batch N; the snapshot captures the adapter's pre-batch state ----
        vault.deposit(depositAmount, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", depositAmount);

        uint256 batchN = adapter.openBatchIds(0);
        {
            (uint128 pd, int128 eurcSnap, uint256 pw, int256 sharesSnap, bool isOpen) = adapter.batchAccounting(batchN);
            assertTrue(isOpen, "phase 1: batch open");
            assertEq(uint256(pd), depositAmount, "phase 1: pendingDeposit = D");
            assertEq(pw, 0, "phase 1: no pendingWithdraw yet");
            assertEq(sharesSnap, int256(seedShares), "phase 1: sharesSnapshotAtBatch = seedShares");
            assertEq(eurcSnap, int128(0), "phase 1: eurcSnapshotAtBatch = 0");
        }
        assertEq(adapter.realAssets(), expected, "phase 1: realAssets = SEED + D");

        // ---- Phase 2: requestWithdraw(W) burns W shares; sharesSnapshot decremented by W ----
        vm.prank(adapterCurator);
        adapter.requestWithdraw(withdrawShares);
        {
            (uint128 pd,, uint256 pw, int256 sharesSnap,) = adapter.batchAccounting(batchN);
            assertEq(uint256(pd), depositAmount, "phase 2: pendingDeposit unchanged");
            assertEq(pw, withdrawShares, "phase 2: pendingWithdraw = W");
            assertEq(sharesSnap, int256(seedShares - withdrawShares), "phase 2: sharesSnapshot decremented by W");
        }
        // Value preserved: shares were burned out of (B), but their value moved to (D) at the same PPS.
        // ±1-wei tolerance for integer-division rounding when W is not a clean multiple of BPEUR_PER_EURC:
        // `convertToAssets((seedShares-W)) + convertToAssets(W)` can round down by 1 vs `convertToAssets(seedShares) =
        // SEED`.
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 2: realAssets preserved post-requestWithdraw");

        // ---- Phase 3: executeDnt — `DntInProgress` flips on. No tickets processed yet ----
        eurVault.executeDnt();
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 3: realAssets preserved post-executeDnt");

        // ---- Phase 4: keeper settles the deposit chunk silently (bpEUR minted to adapter) ----
        // First half of the partial-finalize window: only the deposit ticket has been processed
        // (adapter received its bpEUR) but the batch is NOT closed yet.
        address[] memory receivers = new address[](1);
        receivers[0] = address(adapter);
        eurVault.processDepositChunk(receivers, type(uint256).max);

        // bpEUR balance grew by `D` worth — but the adapter's shadow is intentionally STALE.
        assertEq(
            IERC20(address(eurVault)).balanceOf(address(adapter)),
            seedShares - withdrawShares + depositAmount * BPEUR_PER_EURC,
            "phase 4: shares grew by D worth (deposit ticket silently processed)"
        );
        {
            (uint128 pd,, uint256 pw,,) = adapter.batchAccounting(batchN);
            assertEq(uint256(pd), depositAmount, "phase 4: pendingDeposit shadow STALE (proves correction needed)");
            assertEq(pw, withdrawShares, "phase 4: pendingWithdraw shadow unchanged");
        }
        // The snapshot-delta correction cancels the stale (C) entirely.
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 4: snapshot-delta cancels stale deposit shadow");

        // ---- Phase 5: keeper settles the withdraw chunk silently (EURC paid to adapter) ----
        // Second half of the partial-finalize window. Both tickets are now processed but the batch is
        // STILL not closed.
        eurVault.processWithdrawChunk(receivers, type(uint256).max);

        // EURC paid = withdraw shares valued at seed PPS (W * SEED / seedShares).
        uint256 expectedEurcPaid = withdrawShares.mulDivDown(SEED, seedShares);
        assertEq(eurc.balanceOf(address(adapter)), expectedEurcPaid, "phase 5: EURC paid to adapter");
        {
            (uint128 pd,, uint256 pw,,) = adapter.batchAccounting(batchN);
            assertEq(uint256(pd), depositAmount, "phase 5: pendingDeposit shadow still STALE");
            assertEq(pw, withdrawShares, "phase 5: pendingWithdraw shadow still STALE");
        }

        // Deposit + withdraw snapshot-deltas offset stale (C)/(D); ±1 wei if W doesn’t divide BPEUR_PER_EURC
        // cleanly.
        assertApproxEqAbs(
            adapter.realAssets(), expected, 1, "phase 5: both deltas cancel both stale shadows (within 1 wei)"
        );

        // ---- Phase 6: closeBatch — currentBatchId advances; snapshot branch disarms ----
        // Value carried by branches (A) (EURC paid out) and (B) (live bpEUR balance) alone.
        eurVault.closeBatch();
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 6: post-close, snapshot disarmed, batch skipped");

        // ---- Final: parent vault's totalAssets() coherent with the adapter's realAssets ----
        vault.accrueInterest();
        assertApproxEqAbs(vault.totalAssets(), expected, 1, "final: parentVault.totalAssets coherent");
    }

    /* ------------------------------------------------------------------ */
    /*  Edge cases: negative snapshots (deficit invariants)                */
    /* ------------------------------------------------------------------ */

    /// @notice `sharesSnapshotAtBatch` legitimately goes NEGATIVE when burns exceed the snapshot
    ///         captured at batch open. `realAssets()` must remain correct.
    function testSharesSnapshotGoesNegativeWhenBurnExceedsBatchOpenBalance(uint256 depositAmount, uint256 burnShares)
        public
    {
        depositAmount = bound(depositAmount, 1e6, 100e6); // [1, 100] EURC
        uint256 mintedShares = depositAmount * BPEUR_PER_EURC;
        // Burn must be > 0 and ≤ what was minted.
        burnShares = bound(burnShares, 1, mintedShares);

        // ---- Phase 0: open batch N via `allocate(D)` — adapter starts with ZERO bpEUR ----
        vault.deposit(depositAmount, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", depositAmount);
        uint256 batchN = adapter.openBatchIds(0);
        {
            (uint128 pd,,, int256 sharesSnap, bool isOpen) = adapter.batchAccounting(batchN);
            assertTrue(isOpen, "phase 0: batch N open");
            assertEq(uint256(pd), depositAmount, "phase 0: pendingDeposit = D");
            assertEq(sharesSnap, int256(0), "phase 0: sharesSnapshot at open is 0 (empty adapter)");
        }

        // ---- Phase 1: executeDnt — no settlement yet ----
        eurVault.executeDnt();
        assertEq(adapter.realAssets(), depositAmount, "phase 1: realAssets via pending deposit only");

        // ---- Phase 2: deposit chunk processed silently — shares minted to adapter ----
        address[] memory receivers = new address[](1);
        receivers[0] = address(adapter);
        eurVault.processDepositChunk(receivers, type(uint256).max);
        assertEq(
            IERC20(address(eurVault)).balanceOf(address(adapter)), mintedShares, "phase 2: shares minted to adapter"
        );

        // ---- Phase 3: requestWithdraw(burnShares) mid-DNT ----
        vm.prank(adapterCurator);
        adapter.requestWithdraw(burnShares);

        // ASSERTION: snapshot[N] is now NEGATIVE.
        {
            (,,, int256 sharesSnap,) = adapter.batchAccounting(batchN);
            assertEq(sharesSnap, -int256(burnShares), "phase 3: sharesSnapshot[N] is NEGATIVE (= -burnShares)");
        }

        // Batch N+1 is opened with a fresh post-burn snapshot.
        assertEq(adapter.openBatchIdsLength(), 2, "phase 3: batch N+1 also tracked");
        uint256 batchNplus1 = adapter.openBatchIds(1);
        {
            (,, uint256 pwNext, int256 sharesSnapNext,) = adapter.batchAccounting(batchNplus1);
            assertEq(pwNext, burnShares, "phase 3: pendingWithdraw on batch N+1 = burnShares");
            assertEq(
                sharesSnapNext, int256(mintedShares - burnShares), "phase 3: sharesSnapshot[N+1] = post-burn balance"
            );
        }

        // ---- Phase 4: despite the NEGATIVE snapshot, realAssets must still equal D ----
        // The negative snapshot is what makes sharesDelta recover the FULL mint:
        //     (D * BPEUR_PER_EURC − Y) − (−Y) = D * BPEUR_PER_EURC
        // → eurcDelta = D → pendingDepositEurc=D fully cancelled.
        // ±1 wei tolerance for rounding.
        assertApproxEqAbs(
            adapter.realAssets(), depositAmount, 1, "phase 4: realAssets stays at D even with sharesSnapshot[N] < 0"
        );
    }

    /// @notice `eurcSnapshotAtBatch` legitimately goes NEGATIVE when EURC transfers-out exceed the
    ///         snapshot captured at batch open. Symmetric to the shares-side test.
    function testEurcSnapshotGoesNegativeWhenTransferOutExceedsBatchOpenBalance(uint256 withdrawShares) public {
        uint256 SEED = 100e6; // 100 EURC seed
        uint256 seedShares = SEED * BPEUR_PER_EURC;
        // ≥ 1 EURC worth so payout > 0; ≤ seedShares − 1 leaves ≥ 1 raw share on the adapter so the
        // post-deallocate allocation stays strictly positive (VaultV2 invariant).
        withdrawShares = bound(withdrawShares, BPEUR_PER_EURC, seedShares - 1);
        uint256 expectedPayout = withdrawShares.mulDivDown(SEED, seedShares);
        vm.assume(expectedPayout > 0);

        // ---- Phase 0: seed via a full prior batch (closes cleanly) ----
        vault.deposit(SEED, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", SEED);
        _settleAdapterBatch();
        assertEq(adapter.realAssets(), SEED, "phase 0: post-seed");

        // ---- Phase 1: requestWithdraw(W) opens batch N with eurcSnapshot = 0 ----
        vm.prank(adapterCurator);
        adapter.requestWithdraw(withdrawShares);
        uint256 batchN = adapter.openBatchIds(0);
        {
            (uint128 pd, int128 eurcSnap, uint256 pw, int256 sharesSnap, bool isOpen) = adapter.batchAccounting(batchN);
            assertTrue(isOpen, "phase 1: batch N open");
            assertEq(uint256(pd), 0, "phase 1: no deposit on this batch");
            assertEq(pw, withdrawShares, "phase 1: pendingWithdraw = W");
            assertEq(sharesSnap, int256(seedShares - withdrawShares), "phase 1: sharesSnapshot = seedShares - W");
            assertEq(eurcSnap, int128(0), "phase 1: eurcSnapshot at open = 0 (empty EURC balance)");
        }

        // ---- Phase 2: executeDnt ----
        eurVault.executeDnt();

        // ---- Phase 3: withdraw chunk processed silently — EURC paid to adapter ----
        address[] memory receivers = new address[](1);
        receivers[0] = address(adapter);
        eurVault.processWithdrawChunk(receivers, type(uint256).max);
        assertEq(eurc.balanceOf(address(adapter)), expectedPayout, "phase 3: EURC paid to adapter");
        // realAssets is still SEED at this point — the eurcDelta correction cancels the stale shadow.
        assertApproxEqAbs(adapter.realAssets(), SEED, 1, "phase 3: realAssets stays SEED");

        // ---- Phase 4: vault.deallocate(payout) — eurcSnapshot decremented past zero ----

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", expectedPayout);

        // ASSERTION: eurcSnapshot[N] is now NEGATIVE.
        {
            (, int128 eurcSnap,,,) = adapter.batchAccounting(batchN);
            assertEq(eurcSnap, -int128(int256(expectedPayout)), "phase 4: eurcSnapshot[N] is NEGATIVE (= -payout)");
        }
        assertEq(eurc.balanceOf(address(adapter)), 0, "phase 4: EURC transferred out");

        // ---- Phase 5: despite the NEGATIVE snapshot, realAssets is correct ----
        // The negative snapshot is what makes eurcDelta recover the FULL payout:
        //     0 − (−payout) = payout
        // → pendingWithdrawShares=W (worth `payout`) fully cancelled.
        assertApproxEqAbs(
            adapter.realAssets(),
            SEED - expectedPayout,
            1,
            "phase 5: realAssets = SEED - payout even with eurcSnapshot[N] < 0"
        );
    }

    /* ------------------------------------------------------------------ */
    /*  Swap-fee residue during partial finalize (m=1 only)               */
    /* ------------------------------------------------------------------ */
    //
    // The `_realAssets` NatSpec documents a known transient over-state during the active settlement
    // window of a batch with a non-zero hedge swap fee. The documented upper bound is:
    //
    //  residue_max = (hedgeSwapFeeBps / 10_000) × (dntDepositEurcNet / dntDepositsEurc) ×
    //                 batchAccounting[currentBatchId].pendingDepositEurc

    /// @notice Deposit-side swap-fee residue: between `processDepositChunk` and `closeBatch`,
    ///         `realAssets()` reports the PRE-haircut deposit amount even though the on-chain swap
    ///         loss has already been realized into the EUR vault's reserve. `closeBatch` resolves it.
    /// @dev    Walk-through (D = depositAmount, x = swapFeeBps / 10_000):
    ///           0) `allocate(D)` opens the batch with a pending deposit of D.
    ///           1) `executeDnt` starts settlement.
    ///           2) `processDepositChunk` applies the haircut: adapter ends up with `effective = D * (1 - x)`.
    ///           3) Before close, `realAssets()` over-states by the residue `D - effective`.
    ///           4) `closeBatch` drops the batch from accounting: `realAssets()` becomes exact (= effective).
    function testSwapFeeResidueOnDepositChunkVanishesAtClose(uint256 depositAmount, uint16 swapFeeBps) public {
        swapFeeBps = uint16(bound(uint256(swapFeeBps), 1, 1_000)); // [1bps, 10%], matches existing test bounds
        // Deposit amount, short for "D"
        depositAmount = bound(depositAmount, 1e6, 100e6); // [1, 100] EURC
        eurVault.setHedgeSwapFeeBps(swapFeeBps);

        // Pre-compute the post-haircut "effective" deposit the mock will mint shares against.
        uint256 expectedEffective = depositAmount.mulDivDown(10_000 - uint256(swapFeeBps), 10_000);
        // Actual residue == ceil(depositAmount × swapFeeBps / 10_000)
        uint256 expectedResidue = depositAmount - expectedEffective;
        // Ceiling of the formula documented in NatSpec
        uint256 residue_max = depositAmount.mulDivUp(swapFeeBps, 10_000);
        // Floor of the formula
        uint256 formulaResidueFloor = depositAmount.mulDivDown(swapFeeBps, 10_000);

        // ---- Phase 0: allocate(D) opens batch N — adapter starts EMPTY ----
        vault.deposit(depositAmount, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", depositAmount);
        // Pre-DNT: realAssets counts the pending deposit at face value (fee not yet applied).
        assertEq(adapter.realAssets(), depositAmount, "phase 0: pre-DNT realAssets = D (full pending)");

        // ---- Phase 1: executeDnt — sets _dntSupplySnapshot = 0 (fallback PPS path for conversions) ----
        eurVault.executeDnt();
        assertEq(adapter.realAssets(), depositAmount, "phase 1: realAssets unchanged at DNT entry");

        // ---- Phase 2: silent deposit chunk — adapter receives `effective × BPEUR_PER_EURC` bpEUR ----
        address[] memory receivers = new address[](1);
        receivers[0] = address(adapter);
        eurVault.processDepositChunk(receivers, type(uint256).max);
        // Adapter's bpEUR position only carries the post-haircut value; the swap-loss EURC sits on the
        // EUR vault contract balance.
        assertEq(
            IERC20(address(eurVault)).balanceOf(address(adapter)),
            expectedEffective * BPEUR_PER_EURC,
            "phase 2: bpEUR balance = effective * scale (haircut applied)"
        );

        // ---- Phase 3: load-bearing checks on the mid-DNT residue ----
        uint256 realAssetsMidDnt = adapter.realAssets();

        // (a) realAssets STILL reports the pre-haircut value — the snapshot-delta cancels only the
        //     post-haircut share value out of `pendingDepositEurc=D`, leaving exactly `D − effective`.
        assertEq(realAssetsMidDnt, depositAmount, "phase 3: realAssets over-states (= pre-haircut D)");

        // (b) The over-state is positive
        assertGt(realAssetsMidDnt - expectedEffective, 0, "phase 3: residue strictly positive when fee > 0");

        // (c) The over-state equals the EXACT haircut the mock realized off-chain.
        assertEq(
            realAssetsMidDnt - expectedEffective,
            expectedResidue,
            "phase 3: residue == D - effective (the realized off-chain haircut)"
        );

        // (d) Documented upper bound holds: residue ≤ ceil(residue_max). The floor of the formula is
        //     ≤ the actual residue ≤ the ceil — both are tight to within 1 wei.
        assertLe(
            realAssetsMidDnt - expectedEffective,
            residue_max,
            "phase 3: residue <= ceil(residue_max) - formula tightly bounds the over-state"
        );
        assertLe(
            formulaResidueFloor,
            realAssetsMidDnt - expectedEffective,
            "phase 3: residue >= floor(residue_max) - formula lower bound holds"
        );

        // ---- Phase 4: closeBatch — batch N drops below closedBelow, residue VANISHES ----
        eurVault.closeBatch();
        uint256 realAssetsPostClose = adapter.realAssets();

        // Now realAssets reports the adapter's true holdings: only the post-haircut bpEUR position.
        assertEq(
            realAssetsPostClose, expectedEffective, "phase 4: post-close realAssets = effective (exact, no residue)"
        );
        // The delta between mid-DNT and post-close IS the residue — proof that closeBatch was the
        // event that removed it.
        assertEq(
            realAssetsMidDnt - realAssetsPostClose,
            expectedResidue,
            "phase 4: closeBatch removed EXACTLY the residue (mid-DNT minus post-close)"
        );
    }
}
