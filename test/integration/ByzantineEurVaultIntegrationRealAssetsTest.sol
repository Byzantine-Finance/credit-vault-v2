// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/// @notice Testing `ByzantineEurVaultAdapter.realAssets()`
/// @dev    `realAssets` is the adapter's source of truth for the parent vault's `accrueInterest` loop.
///         Conceptually it is the sum of three branches:
///           (A) idle EURC on the adapter
///           (B) `convertToAssets(bpEUR balance on the adapter)`
///           (C) the value of every live position (`EurVaultPosition.value()`): real holdings
///               (balances + claimables) once its batch closed, the stored pending amount before that.
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
    /*  Branch (A): idle EURC                                             */
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

    /* ------------------------------------------------------------------ */
    /*  Branch (B): bpEUR balance on the adapter                          */
    /* ------------------------------------------------------------------ */

    /// @notice After a gate-open settlement and a sweep, shares sit on the adapter. realAssets must
    ///         count them via `convertToAssets(balanceOf)`.
    function testRealAssetsCountsBpEurBalance() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        _settleAndSweep(); // gate-open settlement + sweep: shares delivered to the adapter

        uint256 shares = IERC20(address(eurVault)).balanceOf(address(adapter));
        assertGt(shares, 0, "shares should be on adapter after the sweep");
        assertEq(adapter.positionsLength(), 0, "no live position left");

        assertEq(adapter.realAssets(), ASSETS_100, "live bpEUR position must be counted via branch (B)");
    }

    /* ------------------------------------------------------------------ */
    /*  Branch (C): settled positions (balances + claimables)             */
    /* ------------------------------------------------------------------ */

    /// @notice After a gate-blocked settlement, shares are parked in `claimableShares[position]`.
    ///         The settled (not yet swept) position must be valued via its claimable shares.
    function testRealAssetsCountsPositionClaimableShares() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        _settleAdapterBatchToClaimable(); // gate-blocked: shares parked as claimable under the position

        address position = adapter.positions(0);
        assertEq(IERC20(address(eurVault)).balanceOf(position), 0, "no live shares (gate-blocked)");
        assertGt(eurVault.claimableShares(position), 0, "shares must sit as claimable");
        assertEq(adapter.realAssets(), ASSETS_100, "claimable shares counted via the settled position");
    }

    /// @notice EURC parked in `claimableEurc[position]` after a gate-blocked withdraw settlement is
    ///         counted via the settled position.
    function testRealAssetsCountsPositionClaimableEurc() public {
        // 1) Deposit + allocate + settle + sweep (gate-open: shares end up on the adapter).
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAndSweep();

        // 2) Burn the shares via requestWithdraw + settle on the gate-blocked path so the EURC payout
        //    sits as claimableEurc under the position instead of being transferred.
        uint256 shares = IERC20(address(eurVault)).balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable();

        address position = adapter.positions(0);
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC expected");
        assertEq(eurVault.claimableEurc(position), ASSETS_100, "claimable EURC must equal deposit");
        assertEq(adapter.realAssets(), ASSETS_100, "claimable EURC counted via the settled position");
    }

    /* ------------------------------------------------------------------ */
    /*  Branch (C): pending positions (stored amounts)                    */
    /* ------------------------------------------------------------------ */

    /// @notice After `vault.allocate` and BEFORE any DNT settlement, the EURC sits in the EUR vault but
    ///         no shares have been minted yet. The whole value must be tracked via the position's
    ///         pending amount.
    function testRealAssetsCountsPendingDepositBeforeSettlement() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        // No DNT yet: adapter has no EURC, no shares; only the position's pending amount carries value.
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC");
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "no shares yet");

        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.pendingEurc(), ASSETS_100, "pending deposit EURC should equal allocated amount");
        assertFalse(position.settled(), "position should be pending");

        assertEq(adapter.realAssets(), ASSETS_100, "pending deposit must be counted via the position");
    }

    /// @notice Multiple allocates in the same (still-idle) batch each get their own position.
    ///         realAssets must equal the sum.
    function testRealAssetsAccumulatesMultiAllocateSameBatch() public {
        vault.deposit(ASSETS_100 + ASSETS_250, address(this));

        vm.startPrank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        vault.allocate(address(adapter), hex"", ASSETS_250);
        vm.stopPrank();

        assertEq(adapter.positionsLength(), 1, "one position per batch (both allocates aggregate)");
        assertEq(adapter.realAssets(), ASSETS_100 + ASSETS_250, "realAssets must equal sum of both allocates");
    }

    /// @notice After `requestWithdraw` burns the adapter's bpEUR but BEFORE the next DNT settlement, the
    ///         position is tracked via `pendingShares`. realAssets must value it via `convertToAssets`.
    function testRealAssetsCountsPendingWithdrawSharesBeforeSettlement() public {
        // Seed the adapter with bpEUR via a full deposit cycle on the gate-open path.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAndSweep();

        // Now burn the shares via requestWithdraw, but do NOT settle yet.
        uint256 shares = IERC20(address(eurVault)).balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Adapter no longer has live shares - they were burned at request time.
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "shares burned at request");

        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.pendingShares(), shares, "pendingShares must equal burned shares");

        // realAssets must value the pending withdraw at the EUR vault's current PPS (= 1 at this point).
        assertEq(adapter.realAssets(), ASSETS_100, "pending withdraw must be counted via the position");
    }

    /* ------------------------------------------------------------------ */
    /*  Multi-depositor / multi-withdrawer flows                          */
    /* ------------------------------------------------------------------ */

    /// @notice With another depositor active in the EUR vault, the adapter's `realAssets` must reflect
    ///         only its OWN position — it must not absorb value contributed by other depositors via the
    ///         shared `totalEurcBacking`.
    function testRealAssetsIsolatedFromOtherDepositors() public {
        address externalUser = makeAddr("externalUser");
        deal(address(eurc), externalUser, ASSETS_250);
        vm.prank(externalUser);
        eurc.approve(address(eurVault), type(uint256).max);

        // 1) Adapter deposits 100 EURC via the normal allocate flow.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        address position = adapter.positions(0);

        // 2) External user deposits 250 EURC directly to the EUR vault, naming themselves as receiver.
        vm.prank(externalUser);
        eurVault.requestDeposit(ASSETS_250, externalUser);

        // Settle both tickets in one DNT cycle.
        address[] memory receivers = new address[](2);
        receivers[0] = position;
        receivers[1] = externalUser;
        eurVault.executeDnt();
        eurVault.processDepositChunk(receivers, type(uint256).max);
        eurVault.processWithdrawChunk(receivers, type(uint256).max);
        eurVault.closeBatch();

        // Adapter's realAssets must equal its own deposit (100 EURC), NOT the total backing (350 EURC).
        assertEq(adapter.realAssets(), ASSETS_100, "adapter realAssets isolated from external depositor");
        // Sanity: each party holds the right share count post-settlement.
        assertEq(IERC20(address(eurVault)).balanceOf(position), ASSETS_100 * BPEUR_PER_EURC, "position shares");
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
        seeders[0] = adapter.positions(0);
        seeders[1] = holder;
        eurVault.executeDnt();
        eurVault.processDepositChunk(seeders, type(uint256).max);
        eurVault.processWithdrawChunk(seeders, type(uint256).max);
        eurVault.closeBatch();
        adapter.sweepSettled(type(uint256).max);

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
        parties[0] = adapter.positions(0); // the adapter's withdraw position
        parties[1] = holder;
        parties[2] = entrant;
        eurVault.executeDnt();
        eurVault.processDepositChunk(parties, type(uint256).max);
        eurVault.processWithdrawChunk(parties, type(uint256).max);
        eurVault.closeBatch();
        adapter.sweepSettled(type(uint256).max);

        // Adapter exited fully at PPS 1.5: 150 EURC paid out, swept home as idle EURC. The
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
    /*  Partial burn before DNT execution                                  */
    /* ------------------------------------------------------------------- */

    /// @notice After a *partial* `requestWithdraw` (NormalIdle, no DNT yet), the burned shares are
    ///         still economically outstanding until the next DNT settles them. The EUR vault must
    ///         preserve PPS across this gap, so `realAssets` must remain equal to the original
    ///         deposit — half from the adapter's remaining bpEUR, half from the position's queued
    ///         burn, both valued at the *pre-burn* share price.
    function testRealAssetsStableAcrossPartialBurnBeforeDnt() public {
        // Seed 100 EURC of bpEUR onto the adapter via a full deposit cycle.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAndSweep();

        uint256 totalShares = IERC20(address(eurVault)).balanceOf(address(adapter));
        uint256 halfShares = totalShares / 2;
        assertGt(halfShares, 0, "must have a meaningful share count for the partial burn");

        // Snapshot the pre-burn realAssets for sanity.
        uint256 realBefore = adapter.realAssets();
        assertEq(realBefore, ASSETS_100, "pre-burn realAssets == deposit");

        // Burn half of the bpEUR — request queued onto the next batch, but no executeDnt yet.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(halfShares);

        // The adapter's bpEUR position is now split between its remaining live shares and the
        // position's queued burn. Both halves are valued at the same pre-burn PPS, so the sum must
        // equal the original deposit (within 1 wei for rounding).
        uint256 realAfter = adapter.realAssets();
        assertApproxEqAbs(realAfter, ASSETS_100, 1, "post-partial-burn realAssets must not inflate");
    }

    /* ------------------------------------------------------------------ */
    /*  Edge case: tickets processed but batch not closed                 */
    /* ------------------------------------------------------------------ */

    /// @notice Core invariant behind the position-isolation design: between ticket processing and
    ///         batch close, settled proceeds land on the POSITIONS (not the adapter), and pending
    ///         positions keep being valued at their stored amounts. No double counting is possible
    ///         because the two sources never overlap.
    /// @dev    Walk-through of the check-points, all asserting `realAssets ≈ SEED + D`:
    ///           0) Seed via a full prior batch -> adapter holds `SEED` worth of bpEUR.
    ///           1) `allocate(D)` opens a deposit position on batch N.
    ///           2) `requestWithdraw(W)` opens a withdraw position on batch N (burns W shares).
    ///           3) `executeDnt()` flips `DntInProgress`. No tickets processed yet.
    ///           4) `processDepositChunk` settles the deposit ticket: bpEUR minted to the DEPOSIT
    ///              POSITION; the position is still valued at `pendingEurc` (close-based), and the
    ///              minted shares are NOT counted (they sit on the position, not the adapter).
    ///           5) `processWithdrawChunk` settles the withdraw ticket: EURC paid to the WITHDRAW
    ///              POSITION; same isolation argument.
    ///           6) `closeBatch` — both positions flip to settled and are valued by their real
    ///              holdings; a sweep brings everything home.
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
        _settleAndSweep(); // gate-open: shares minted to the position, then swept to the adapter
        assertEq(adapter.realAssets(), SEED, "phase 0: post-seed realAssets == SEED");
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), seedShares, "phase 0: adapter holds seedShares");

        // ---- Phase 1: allocate(D) opens a deposit position on batch N ----
        vault.deposit(depositAmount, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", depositAmount);
        address depositPosition = adapter.positions(0);
        assertEq(adapter.realAssets(), expected, "phase 1: realAssets = SEED + D");

        // ---- Phase 2: requestWithdraw(W) opens a withdraw position on batch N ----
        vm.prank(adapterCurator);
        adapter.requestWithdraw(withdrawShares);
        address withdrawPosition = adapter.positions(1);
        // Value preserved: shares were burned out of the adapter, but their value moved to the
        // position at the same PPS. ±1-wei tolerance for integer-division rounding when W is not a
        // clean multiple of BPEUR_PER_EURC.
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 2: realAssets preserved post-requestWithdraw");

        // ---- Phase 3: executeDnt — `DntInProgress` flips on. No tickets processed yet ----
        eurVault.executeDnt();
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 3: realAssets preserved post-executeDnt");

        // ---- Phase 4: keeper settles the deposit chunk silently (bpEUR minted to the position) ----
        address[] memory receivers = new address[](2);
        receivers[0] = depositPosition;
        receivers[1] = withdrawPosition;
        eurVault.processDepositChunk(receivers, type(uint256).max);

        // The position received its bpEUR, but it is still valued at `pendingEurc` (close-based) and
        // the minted shares are NOT double counted (they are on the position, not the adapter).
        assertEq(
            IERC20(address(eurVault)).balanceOf(depositPosition),
            depositAmount * BPEUR_PER_EURC,
            "phase 4: deposit ticket silently processed onto the position"
        );
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 4: no double counting mid-finalize");

        // ---- Phase 5: keeper settles the withdraw chunk silently (EURC paid to the position) ----
        eurVault.processWithdrawChunk(receivers, type(uint256).max);

        // EURC paid = withdraw shares valued at seed PPS (W * SEED / seedShares).
        uint256 expectedEurcPaid = withdrawShares.mulDivDown(SEED, seedShares);
        assertEq(eurc.balanceOf(withdrawPosition), expectedEurcPaid, "phase 5: EURC paid to the position");
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 5: no double counting either side");

        // ---- Phase 6: closeBatch — both positions settle; the sweep brings everything home ----
        eurVault.closeBatch();
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 6: post-close, settled positions valued real");

        adapter.sweepSettled(type(uint256).max);
        assertEq(adapter.positionsLength(), 0, "phase 6: positions swept");
        assertApproxEqAbs(adapter.realAssets(), expected, 1, "phase 6: post-sweep value preserved");

        // ---- Final: parent vault's totalAssets() coherent with the adapter's realAssets ----
        vault.accrueInterest();
        assertApproxEqAbs(vault.totalAssets(), expected, 1, "final: parentVault.totalAssets coherent");
    }

    /* ------------------------------------------------------------------ */
    /*  Audit-finding regression: stale valuation of a batch opened       */
    /*  during the previous batch's DNT                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Regression for the audited stale-snapshot understatement (deposit side).
    ///         A request made DURING batch N's DNT queues on batch N+1. Batch N then settles and
    ///         closes WITHOUT any adapter call, and batch N+1 enters its own DNT. The audited
    ///         snapshot-delta design misattributed batch N's settlement to batch N+1 and zeroed its
    ///         pending value (reported 150 instead of 200 in the finding's walk-through). With
    ///         per-position isolation no re-anchor is needed: realAssets must stay exact.
    function testRealAssetsNoUnderstatementForBatchOpenedDuringPriorDnt() public {
        // Batch N: allocate A1, then enter DNT.
        vault.deposit(ASSETS_100 + ASSETS_250, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        eurVault.executeDnt();

        // Mid-DNT: allocate A2 — queues on batch N+1 in its own position.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_250);

        // Settle + close batch N. NO adapter state-changing call afterwards.
        address[] memory r = new address[](1);
        r[0] = adapter.positions(0);
        eurVault.processDepositChunk(r, type(uint256).max);
        eurVault.processWithdrawChunk(r, type(uint256).max);
        eurVault.closeBatch();

        // Batch N+1 enters its own DNT — the audited design understated realAssets right here.
        eurVault.executeDnt();

        assertEq(adapter.realAssets(), ASSETS_100 + ASSETS_250, "no understatement mid-DNT of batch N+1");
    }

    /// @notice Regression for the audited re-anchor double-count (Sherlock issue #4): in the old
    ///         snapshot design, a permissionless pull during batch N+1's partial settlement
    ///         re-anchored N+1's snapshot to balances that already included N+1's own mint,
    ///         disabling the correction and over-stating realAssets by exactly A2 (200 instead of
    ///         150 in the finding's walkthrough). With per-position isolation, N+1's minted bpEUR
    ///         sit on the position (not the adapter) and the position is valued at its pending
    ///         amount until close — no shadow left to double count, and the sweep cannot interfere.
    function testRealAssetsNoDoubleCountAfterSweepDuringPartialSettlement() public {
        uint256 A1 = ASSETS_100; // batch1 deposit
        uint256 A2 = 50e6; // batch2 deposit, the amount double-counted in the finding

        // Steps 1-3: allocate A1 (batch1), enter DNT, allocate A2 mid-DNT (batch2).
        vault.deposit(A1 + A2, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", A1);
        eurVault.executeDnt();
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", A2);
        address position1 = adapter.positions(0);
        address position2 = adapter.positions(1);

        // Step 4: settle + close batch1 — position1 holds A1's bpEUR, "settled but still listed".
        address[] memory r1 = new address[](1);
        r1[0] = position1;
        eurVault.processDepositChunk(r1, type(uint256).max);
        eurVault.processWithdrawChunk(r1, type(uint256).max);
        eurVault.closeBatch();

        // Steps 5-6: batch2 enters DNT and its deposit chunk is processed WITHOUT closing.
        eurVault.executeDnt();
        address[] memory r2 = new address[](1);
        r2[0] = position2;
        eurVault.processDepositChunk(r2, type(uint256).max);
        assertEq(eurVault.balanceOf(position2), A2 * BPEUR_PER_EURC, "position2 silently minted");

        // The trigger of the audited bug: a permissionless sweep (analog of pullClaimableShares)
        // while batch2 is mid-settlement. position1 is swept home; position2 must be untouched.
        adapter.sweepSettled(type(uint256).max);
        assertEq(eurVault.balanceOf(address(adapter)), A1 * BPEUR_PER_EURC, "A1 bpEUR swept to the adapter");
        assertEq(adapter.positionsLength(), 1, "position2 (in-flight) survives the sweep");

        // The audited design reported A1 + 2*A2 (200) here. Position isolation must report A1 + A2.
        assertEq(adapter.realAssets(), A1 + A2, "no double count after sweep during partial settlement");

        // Sanity: still exact after the batch closes and the last position is swept.
        eurVault.processWithdrawChunk(r2, type(uint256).max);
        eurVault.closeBatch();
        adapter.sweepSettled(type(uint256).max);
        assertEq(adapter.realAssets(), A1 + A2, "exact after close + final sweep");
    }

    /// @notice Regression for the audited fabricated-delta understatement (Sherlock issue #7): in
    ///         the old design, `requestDeposit` mid-DNT subtracted the outgoing EURC from EVERY open
    ///         batch's snapshot, driving batch N+1's snapshot artificially negative; when N+1 later
    ///         entered its own DNT, the fabricated delta cancelled its genuine pending withdrawal.
    ///         With isolated positions there is no snapshot to corrupt: a mid-DNT deposit is just a
    ///         new position, and batch N's payout sits untouched on its own position until close.
    function testRealAssetsNoFabricatedDeltaFromMidDntDeposit() public {
        uint256 SEED = 1000e6;
        uint256 W = 400e6;
        uint256 wShares = W * BPEUR_PER_EURC;

        // Seed the adapter with 1000 EURC of bpEUR.
        vault.deposit(SEED, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", SEED);
        _settleAndSweep();

        // Batch N: withdraw 400, then enter DNT.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(wShares);
        address positionW1 = adapter.positions(0);
        eurVault.executeDnt();

        // Mid-DNT: second withdraw of 400 — queues on batch N+1 in its own position.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(wShares);

        // Batch N's withdrawal settles: 400 EURC paid to positionW1 (batch NOT closed yet).
        address[] memory r = new address[](1);
        r[0] = positionW1;
        eurVault.processWithdrawChunk(r, type(uint256).max);
        assertEq(eurc.balanceOf(positionW1), W, "batch N payout isolated on its position");
        assertApproxEqAbs(adapter.realAssets(), SEED, 1, "value preserved mid-settlement");

        // The audited trigger: an outgoing EURC deposit request mid-DNT, queued on batch N+1.
        // (External idle EURC: batch N's payout is locked on its position until the batch closes.)
        deal(address(eurc), address(adapter), W);
        vm.prank(adapterCurator);
        adapter.requestDeposit(W);
        assertApproxEqAbs(adapter.realAssets(), SEED + W, 1, "deposit added, nothing fabricated");

        // Close batch N, then enter batch N+1's own DNT — where the audited design understated
        // by the fabricated delta (~400 EURC).
        eurVault.closeBatch();
        eurVault.executeDnt();

        assertApproxEqAbs(adapter.realAssets(), SEED + W, 1, "no understatement during batch N+1's DNT");
    }

    /// @notice Regression for the audited bpEUR-injection undercount (Sherlock issue #11): in the
    ///         old design, bpEUR sent directly to the adapter inflated the `current − snapshot`
    ///         delta, which was misread as the current batch's settled deposit and zeroed its
    ///         pending shadow (reporting 100 instead of 200 in the finding's walkthrough). Pendings
    ///         now live on isolated positions and are never reduced by the adapter's balance: an
    ///         injection can only ADD value (upward direction, smoothed by the parent's maxRate).
    function testRealAssetsInjectedBpEurDoesNotCancelPendingDeposit() public {
        // Pending deposit of 100 on the current batch.
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        // A third party injects 100 EURC worth of bpEUR directly onto the ADAPTER.
        deal(address(eurVault), address(adapter), ASSETS_100 * BPEUR_PER_EURC);
        assertEq(adapter.realAssets(), 2 * ASSETS_100, "pre-DNT: injected value + pending deposit");

        // DNT starts before the adapter's ticket settles — the audited code misread the injected
        // bpEUR as the settled ticket right here and dropped to 100.
        eurVault.executeDnt();
        assertEq(adapter.realAssets(), 2 * ASSETS_100, "mid-DNT: injection cannot cancel the pending deposit");
    }

    /// @notice Same regression on the withdraw side: a withdraw requested during batch N's DNT
    ///         queues on batch N+1; after N closes silently and N+1 enters DNT, the pending withdraw
    ///         must still be fully valued.
    function testRealAssetsNoUnderstatementForWithdrawOpenedDuringPriorDnt() public {
        uint256 SEED = 200e6;
        uint256 seedShares = SEED * BPEUR_PER_EURC;
        uint256 w = seedShares / 4; // 50 EURC worth per withdraw

        // Seed the adapter with bpEUR.
        vault.deposit(SEED, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", SEED);
        _settleAndSweep();

        // Batch N: first withdraw, then enter DNT.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(w);
        address position1 = adapter.positions(0);
        eurVault.executeDnt();

        // Mid-DNT: second withdraw — queues on batch N+1 in its own position.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(w);

        // Settle + close batch N (pays position1). NO adapter call afterwards.
        address[] memory r = new address[](1);
        r[0] = position1;
        eurVault.processDepositChunk(r, type(uint256).max);
        eurVault.processWithdrawChunk(r, type(uint256).max);
        eurVault.closeBatch();

        // Batch N+1 enters its own DNT — the audited design wrongly zeroed position2's pending here.
        eurVault.executeDnt();

        assertApproxEqAbs(adapter.realAssets(), SEED, 1, "no understatement mid-DNT of batch N+1 (withdraw side)");
    }

    /* ------------------------------------------------------------------ */
    /*  Donation resistance                                               */
    /* ------------------------------------------------------------------ */

    /// @notice Donating bpEUR or EURC to a PENDING position must not change its valuation: the
    ///         pending branch of `value()` reads no balances, so a 1-wei donation cannot flip the
    ///         position into being valued by its (near-zero) real holdings.
    function testRealAssetsDonationToPendingPositionIsIgnored() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        address position = adapter.positions(0);

        // Donate 1 wei of bpEUR and 1 wei of EURC to the pending position.
        deal(address(eurVault), position, 1);
        deal(address(eurc), position, 1);

        assertEq(adapter.realAssets(), ASSETS_100, "donations cannot flip a pending position's valuation");
    }

    /// @notice Donations to a SETTLED position are simply extra value (counted, then swept home):
    ///         the error direction is upward only, which the parent vault's maxRate cap smooths.
    function testRealAssetsDonationToSettledPositionOnlyAddsValue() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAdapterBatch();
        address position = adapter.positions(0);

        uint256 donation = 5e6;
        deal(address(eurc), position, donation);

        assertEq(adapter.realAssets(), ASSETS_100 + donation, "settled donation adds value (upward only)");

        adapter.sweepSettled(type(uint256).max);
        assertEq(eurc.balanceOf(address(adapter)), donation, "donation swept home with the proceeds");
        assertEq(adapter.realAssets(), ASSETS_100 + donation, "value preserved after the sweep");
    }

    /* ------------------------------------------------------------------ */
    /*  Swap-fee residue during partial finalize (m=1 only)               */
    /* ------------------------------------------------------------------ */
    //
    // The `EurVaultPosition.value()` NatSpec documents a known transient over-statement during the
    // active settlement window of a batch with a non-zero hedge swap fee. The documented upper bound:
    //
    //  residue_max = (hedgeSwapFeeBps / 10_000) × (dntDepositEurcNet / dntDepositsEurc) × pendingEurc

    /// @notice Deposit-side swap-fee residue: between `processDepositChunk` and `closeBatch`,
    ///         `realAssets()` reports the PRE-haircut pending amount even though the on-chain swap
    ///         loss has already been realized into the EUR vault's reserve. `closeBatch` resolves it.
    /// @dev    Walk-through (D = depositAmount, x = swapFeeBps / 10_000):
    ///           0) `allocate(D)` opens a position with a pending deposit of D.
    ///           1) `executeDnt` starts settlement.
    ///           2) `processDepositChunk` applies the haircut: the position receives `effective = D * (1 - x)`
    ///              worth of bpEUR, but is still valued at its stored pending amount (close-based).
    ///           3) Before close, `realAssets()` over-states by the residue `D - effective`.
    ///           4) `closeBatch` flips the position to settled: `realAssets()` becomes exact (= effective).
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

        // ---- Phase 0: allocate(D) opens a position — adapter starts EMPTY ----
        vault.deposit(depositAmount, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", depositAmount);
        address position = adapter.positions(0);
        // Pre-DNT: realAssets counts the pending deposit at face value (fee not yet applied).
        assertEq(adapter.realAssets(), depositAmount, "phase 0: pre-DNT realAssets = D (full pending)");

        // ---- Phase 1: executeDnt — sets _dntSupplySnapshot = 0 (fallback PPS path for conversions) ----
        eurVault.executeDnt();
        assertEq(adapter.realAssets(), depositAmount, "phase 1: realAssets unchanged at DNT entry");

        // ---- Phase 2: silent deposit chunk — the position receives `effective × BPEUR_PER_EURC` bpEUR ----
        address[] memory receivers = new address[](1);
        receivers[0] = position;
        eurVault.processDepositChunk(receivers, type(uint256).max);
        // The position's bpEUR only carries the post-haircut value; the swap-loss EURC sits on the
        // EUR vault contract balance.
        assertEq(
            IERC20(address(eurVault)).balanceOf(position),
            expectedEffective * BPEUR_PER_EURC,
            "phase 2: bpEUR balance = effective * scale (haircut applied)"
        );

        // ---- Phase 3: load-bearing checks on the mid-DNT residue ----
        uint256 realAssetsMidDnt = adapter.realAssets();

        // (a) realAssets STILL reports the pre-haircut value — the position is valued at its stored
        //     pending amount until its batch closes (close-based valuation).
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

        // ---- Phase 4: closeBatch — the position settles, residue VANISHES ----
        eurVault.closeBatch();
        uint256 realAssetsPostClose = adapter.realAssets();

        // Now realAssets reports the position's true holdings: only the post-haircut bpEUR.
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

    /* ------------------------------------------------------------------ */
    /*  Swap-fee + withdraw-fee residue during partial finalize           */
    /*  (withdraw side, m=1 only)                                         */
    /* ------------------------------------------------------------------ */
    //
    // `EurVaultPosition.value()` NatSpec documents the same transient over-statement for a withdraw
    // ticket. The protocol withdraw fee is already deducted live (`previewRedeemNetAssets`), so the
    // remaining residue is the swap-fee component only (plus the gross-vs-post-swap fee-base rounding):
    //
    //   pendingNet = owed - ceil(owed × withdrawFeeBps / 10_000)        // what realAssets reports
    //   toPay      = afterSwap - ceil(afterSwap × withdrawFeeBps / 10_000)
    //   residue    = pendingNet - toPay  <=  ceil(owed × swapFeeBps / 10_000)

    /// @notice Withdraw-side fee residue: between `processWithdrawChunk` and `closeBatch`,
    ///         `realAssets()` reports the pending amount net of the protocol fee but still GROSS of
    ///         the swap haircut (only realized at settlement). `closeBatch` resolves it.
    ///
    /// @dev    Full-seed withdraw (W = all seeded shares), so the adapter retains no bpEUR/EURC and the
    ///         position is the ONLY source of value — isolating the residue.
    ///         Walk-through (x_s = swapFeeBps/10_000, x_w = withdrawFeeBps/10_000):
    ///           0) seed + requestWithdraw(W) opens a withdraw position with pendingShares = W.
    ///              The protocol fee is recognized HERE: realAssets = owed - ceil(owed·x_w).
    ///           1) executeDnt locks the snapshot. realAssets unchanged (= pendingNet).
    ///           2) processWithdrawChunk pays `toPay = floor(owed·(1-x_s)) - ceil(afterSwap·x_w)` to the
    ///              position, but it is still valued at pendingNet (close-based).
    ///           3) Before close, realAssets over-states by `pendingNet - toPay` (swap component only).
    ///           4) closeBatch flips the position to settled: realAssets = toPay (exact, no residue).
    function testSwapFeeResidueOnWithdrawChunkVanishesAtClose(
        uint256 seedEurc,
        uint16 swapFeeBps,
        uint16 withdrawFeeBps
    ) public {
        swapFeeBps = uint16(bound(uint256(swapFeeBps), 1, 1_000)); // [1bps, 10%]
        withdrawFeeBps = uint16(bound(uint256(withdrawFeeBps), 1, 1_000)); // [1bps, 10%]
        seedEurc = bound(seedEurc, 1e6, 100e6); // [1, 100] EURC

        // ---- Phase 0: seed the adapter with `seedEurc` worth of bpEUR (gate-open, PPS 1.0) ----
        // Fees are still zero here, so the seed deposit mints shares 1:1 and is itself unaffected.
        vault.deposit(seedEurc, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", seedEurc);
        _settleAndSweep();

        uint256 seedShares = IERC20(address(eurVault)).balanceOf(address(adapter));
        assertEq(seedShares, seedEurc * BPEUR_PER_EURC, "phase 0: seeded shares at PPS 1.0");

        // Turn the fees on AFTER seeding so only the withdraw settlement pays them.
        eurVault.setHedgeSwapFeeBps(swapFeeBps);
        eurVault.setWithdrawFeeBps(withdrawFeeBps);

        // ---- Phase 1: requestWithdraw(W) burns ALL the adapter's bpEUR into a withdraw position ----
        vm.prank(adapterCurator);
        adapter.requestWithdraw(seedShares);
        address position = adapter.positions(0);
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "phase 1: adapter fully burned");
        // Pre-DNT: the pending withdraw is valued at the live PPS (= 1.0), NET of the protocol fee
        // (recognized at request via previewRedeemNetAssets). The swap haircut is not known yet.
        uint256 owed = seedEurc;
        uint256 pendingNet = owed - owed.mulDivUp(uint256(withdrawFeeBps), 10_000);
        assertEq(adapter.realAssets(), pendingNet, "phase 1: pre-DNT realAssets = owed net of protocol fee");

        // ---- Phase 2: executeDnt locks the NAV/supply snapshot ----
        eurVault.executeDnt();
        assertEq(adapter.realAssets(), pendingNet, "phase 2: realAssets unchanged at DNT entry");

        // Pre-compute `toPay`, mirroring `processWithdrawChunk`'s fee order. The full withdraw at
        // snapshot PPS 1.0 makes `owed == seedEurc` exactly (W·nav/supply with nav==seed, supply==W).
        uint256 afterSwap = owed.mulDivDown(10_000 - uint256(swapFeeBps), 10_000); // swap haircut (floor)
        uint256 withdrawFee = afterSwap.mulDivUp(uint256(withdrawFeeBps), 10_000); // protocol fee (ceil)
        uint256 toPay = afterSwap - withdrawFee;
        uint256 expectedResidue = pendingNet - toPay;

        // The residue is now the swap component only: bounded by ceil(owed·x_s).
        // Identity: owed - floor(owed·(1-x_s)) == ceil(owed·x_s).
        uint256 swapLoss = owed.mulDivUp(uint256(swapFeeBps), 10_000);
        assertLe(expectedResidue, swapLoss, "residue <= ceil(owed*swap) (protocol fee pre-deducted)");

        // ---- Phase 3: silent withdraw chunk — EURC paid to the position, post BOTH fees ----
        address[] memory receivers = new address[](1);
        receivers[0] = position;
        eurVault.processWithdrawChunk(receivers, type(uint256).max);
        assertEq(eurc.balanceOf(position), toPay, "phase 3: position paid `toPay` (both fees realized)");

        // ---- Phase 3 checks: load-bearing assertions on the mid-DNT residue ----
        uint256 realAssetsMidDnt = adapter.realAssets();

        // (a) realAssets STILL reports `pendingNet` — the burned shares are valued at the snapshot
        //     PPS net of the protocol fee until the batch closes, ignoring the realized swap loss.
        assertEq(realAssetsMidDnt, pendingNet, "phase 3: realAssets over-states (= pendingNet)");

        // (b) The over-state is strictly positive (swap fee > 0).
        assertGt(realAssetsMidDnt - toPay, 0, "phase 3: residue strictly positive when swap fee > 0");

        // (c) The over-state equals the EXACT residue the mock realized off the payout.
        assertEq(realAssetsMidDnt - toPay, expectedResidue, "phase 3: residue == pendingNet - toPay");

        // (d) Documented bound holds: the residue is the swap component only.
        assertLe(realAssetsMidDnt - toPay, swapLoss, "phase 3: residue lte documented swap-fee bound");

        // ---- Phase 4: closeBatch — the position settles, residue DISAPPEARS ----
        eurVault.closeBatch();
        uint256 realAssetsPostClose = adapter.realAssets();

        // The settled position is now valued by its real EURC holding only (the swept-able payout).
        assertEq(realAssetsPostClose, toPay, "phase 4: post-close realAssets = toPay (exact, no residue)");
        // The delta IS the residue — proof that closeBatch was the event that removed it.
        assertEq(
            realAssetsMidDnt - realAssetsPostClose,
            expectedResidue,
            "phase 4: closeBatch removed EXACTLY the residue (mid-DNT minus post-close)"
        );
    }

    /* ------------------------------------------------------------------ */
    /*  Loss scenario: PPS < 1.0 passes through immediately (downward)    */
    /* ------------------------------------------------------------------ */

    /// @notice A loss in the EUR vault (PPS < 1.0) must pass through `realAssets()` IMMEDIATELY and in the
    ///         DOWNWARD direction — for bpEUR held directly by the adapter (branch B) and for a pending
    ///         withdraw position valued via `convertToAssets(pendingShares)`. Unlike the upward donation /
    ///         swap-fee-residue cases, a loss is NOT smoothed or capped: it is reflected at once. This is
    ///         exactly the "phantom loss" direction the `value()` NatSpec calls out — an under-statement
    ///         passes straight through, so the valuation must track the live (loss-adjusted) PPS.
    function testRealAssetsReflectsLoss(uint256 seedEurc, uint256 lossEurc) public {
        seedEurc = bound(seedEurc, 2e6, 100e6); // [2, 100] EURC
        lossEurc = bound(lossEurc, 1e6, seedEurc - 1e6); // strict partial loss: 0 < loss < seed

        // Seed the adapter with `seedEurc` worth of bpEUR at PPS 1.0.
        vault.deposit(seedEurc, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", seedEurc);
        _settleAndSweep();

        uint256 seedShares = IERC20(address(eurVault)).balanceOf(address(adapter));
        assertEq(adapter.realAssets(), seedEurc, "pre-loss realAssets == seed (PPS 1.0)");

        // Apply the loss: backing drops from `seedEurc` to `seedEurc - lossEurc`, so PPS < 1.0.
        eurVault.setShareRate(-int256(lossEurc));
        uint256 expected = seedEurc - lossEurc;

        // Branch B (adapter's idle bpEUR) tracks the reduced PPS immediately — no smoothing on the way down.
        assertEq(adapter.realAssets(), expected, "loss passes through realAssets immediately (branch B)");
        assertLt(adapter.realAssets(), seedEurc, "loss is reflected downward, not smoothed");

        // The same loss must flow through a PENDING WITHDRAW position: burning the shares moves their
        // value to the position, still priced at the live (loss-adjusted) PPS via convertToAssets.
        vm.prank(adapterCurator);
        adapter.requestWithdraw(seedShares);
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.pendingShares(), seedShares, "pending withdraw holds the burned shares");
        assertEq(IERC20(address(eurVault)).balanceOf(address(adapter)), 0, "adapter bpEUR fully burned");
        assertEq(adapter.realAssets(), expected, "pending withdraw reflects the loss at live PPS");
    }
}
