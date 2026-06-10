// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {ByzantineEurVaultAdapter} from "../../src/adapters/ByzantineEurVaultAdapter.sol";
import {IEurVaultPosition} from "../../src/adapters/interfaces/IEurVaultPosition.sol";

contract ByzantineEurVaultIntegrationWithdrawTest is ByzantineEurVaultIntegrationTest {
    /* requestWithdraw ACCESS CONTROL */

    function testRequestWithdrawOnlyAdapterCurator(address invalidCaller) public {
        vm.assume(invalidCaller != adapterCurator);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.requestWithdraw(1);
    }

    function testRequestWithdrawZeroSharesRevertsAtEurVault() public {
        vm.prank(adapterCurator);
        vm.expectRevert(MockByzantinePrimeEURVault.ZeroShares.selector);
        adapter.requestWithdraw(0);
    }

    function testRequestWithdrawMoreThanHeldReverts(uint256 shares) public {
        shares = bound(shares, 1, type(uint128).max);
        // The adapter holds no bpEUR: any non-zero request must revert before touching the EUR vault.
        vm.prank(adapterCurator);
        vm.expectRevert(IByzantineEurVaultAdapter.InsufficientShares.selector);
        adapter.requestWithdraw(shares);
    }

    function testInitWithdrawOnlyAdapter(address caller, uint256 shares) public {
        vm.assume(caller != address(adapter));
        shares = bound(shares, 1, type(uint128).max);

        // Open a real withdraw position through the adapter so we have a live clone to poke at.
        vault.deposit(100e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", 100e6);
        _settleAndSweep();
        uint256 heldShares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(heldShares);
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));

        // The `msg.sender == adapter` guard is checked first, so any non-adapter caller is rejected.
        vm.expectRevert(IEurVaultPosition.NotAdapter.selector);
        vm.prank(caller);
        position.initWithdraw(shares);
    }

    function testInitWithdrawCannotReinitialize() public {
        // Open a withdraw position; `batchId` is now set, so the clone counts as initialized.
        vault.deposit(100e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", 100e6);
        _settleAndSweep();
        uint256 heldShares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(heldShares);
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertGt(position.batchId(), 0, "position must be initialized (batchId set)");

        // Pass the `NotAdapter` guard by impersonating the adapter, then trip `AlreadyInitialized`.
        vm.expectRevert(IEurVaultPosition.AlreadyInitialized.selector);
        vm.prank(address(adapter));
        position.initWithdraw(1);
    }

    /* setAdapterCurator ACCESS CONTROL & STATE */

    function testSetAdapterCuratorOnlyVaultCurator(address invalidCaller, address newAdapterCurator) public {
        vm.assume(invalidCaller != curator);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.setAdapterCurator(newAdapterCurator);
    }

    function testSetAdapterCuratorEmitsAndStores(address newAdapterCurator) public {
        vm.expectEmit(true, false, false, false, address(adapter));
        emit IByzantineEurVaultAdapter.SetAdapterCurator(newAdapterCurator);
        vm.prank(curator);
        adapter.setAdapterCurator(newAdapterCurator);
        assertEq(adapter.adapterCurator(), newAdapterCurator, "adapterCurator stored");
    }

    /* ROLE ROTATION SEMANTICS */

    function testRotatingAdapterCuratorRevokesPreviousCurator(address newAdapterCurator) public {
        vm.assume(newAdapterCurator != adapterCurator);
        vm.assume(newAdapterCurator != address(0));

        vm.prank(curator);
        adapter.setAdapterCurator(newAdapterCurator);

        // Previous adapter curator must no longer be able to call requestWithdraw.
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(1);
    }

    function testRotatingAdapterCuratorActivatesNewCurator(uint256 assets, address newAdapterCurator) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vm.assume(newAdapterCurator != adapterCurator);
        vm.assume(newAdapterCurator != address(0));

        // Set up bpEUR on the adapter via a settled + swept deposit cycle.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();
        uint256 shares = eurVault.balanceOf(address(adapter));

        // Rotate the curator.
        vm.prank(curator);
        adapter.setAdapterCurator(newAdapterCurator);

        // The new curator can call requestWithdraw.
        vm.prank(newAdapterCurator);
        adapter.requestWithdraw(shares);
        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares burned via new curator");
    }

    /* requestWithdraw HAPPY PATH & SEMANTICS */

    function testRequestWithdrawBurnsSharesAndQueuesPayout(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep(); // shares on adapter

        uint256 shares = eurVault.balanceOf(address(adapter));
        uint256 batchId = _activeBatchId();

        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Shares moved to the position and burned immediately.
        assertEq(eurVault.balanceOf(address(adapter)), 0, "adapter shares gone");
        assertEq(adapter.positionsLength(), 1, "one live position");
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(eurVault.balanceOf(address(position)), 0, "position shares burned");
        assertEq(position.pendingShares(), shares, "pendingShares");
        assertEq(position.pendingEurc(), 0, "withdraw position has no pendingEurc");
        assertEq(position.batchId(), batchId, "position batchId");
    }

    function testRequestWithdrawEmitsEvent(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();

        uint256 shares = eurVault.balanceOf(address(adapter));
        uint256 batchId = _activeBatchId();

        // topic1 (the position address) is not checked: it is derived from the CREATE2 nonce.
        vm.expectEmit(false, true, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.RequestWithdraw(address(0), batchId, shares);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
    }

    function testRequestWithdrawSweepsClaimableSharesFirst(uint256 assets) public {
        // When deposit shares are gate-blocked into `claimableShares` under a settled deposit position,
        // `requestWithdraw` must sweep them home before burning.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatchToClaimable(); // gate-blocked path: shares stay claimable under the position

        // Pre-state: nothing on the adapter; everything sitting as claimable under the deposit position.
        address depositPosition = adapter.positions(0);
        uint256 claimable = eurVault.claimableShares(depositPosition);
        assertGt(claimable, 0, "should have claimable shares");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "no adapter shares before sweep");

        vm.prank(adapterCurator);
        adapter.requestWithdraw(claimable); // adapter sweeps then burns in one shot

        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares swept and burned");
        assertEq(eurVault.claimableShares(depositPosition), 0, "claimable shares drained");
        // The settled deposit position was dropped; only the fresh withdraw position remains.
        assertEq(adapter.positionsLength(), 1, "one live position (the new withdraw)");
        assertEq(EurVaultPosition(adapter.positions(0)).pendingShares(), claimable, "pendingShares == swept claimable");
    }

    function testRequestWithdrawRealAssetsPreservesValueBeforeAndAfterSettlement(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();

        uint256 realAssetsBefore = adapter.realAssets();
        uint256 shares = eurVault.balanceOf(address(adapter));

        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // realAssets must not change just from queuing a withdrawal (shares -> pendingShares value).
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged on request");

        _settleAdapterBatch();
        // After settlement, the EURC sits on the settled position (gate-open path) — realAssets must still match.
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged on settlement");

        adapter.sweepSettled(type(uint256).max);
        // After the sweep, the EURC is idle on the adapter — realAssets must still match.
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged after sweep");
    }

    /* WITHDRAW AND HEDGE SWAP FEES (4 SCENARIOS) */

    /// @notice Scenario 1: Withdraw fee deducted at settlement - gate-open: adapter receives `gross - fee`
    ///         after the sweep, the fee EURC stays on the EUR vault.
    function testWithdrawFeeReducesPayoutByFeeBps(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000)); // up to 10%
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setWithdrawFeeBps(feeBps);

        // Seed the adapter with bpEUR via a normal deposit cycle (no deposit fee).
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();

        // Burn all of the adapter's bpEUR.
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Settle on the gate-open path and sweep the payout home.
        _settleAndSweep();

        // mulDivUp formula matches the mock's `_mulDivUp(owed, feeBps, 10_000)`.
        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedPayout = assets - expectedFee;

        assertEq(eurc.balanceOf(address(adapter)), expectedPayout, "adapter receives gross - fee");
        assertEq(eurc.balanceOf(address(eurVault)), expectedFee, "fee EURC retained on EUR vault");
        // The bpEUR supply is now empty and so is the backing — fees do not back any outstanding share.
        assertEq(eurVault.totalEurcBacking(), 0, "backing fully drained by gross owed");
    }

    /// @notice Scenario 2: Hedge swap fee only: Adapter receives `gross * (1 - swapFeeBps/10000)` EURC at settlement.
    ///         The swap-loss EURC stays on the EUR vault contract balance.
    function testSwapFeeHaircutsWithdrawPayout(uint256 assets, uint16 swapFeeBps) public {
        swapFeeBps = uint16(bound(swapFeeBps, 1, 1_000));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed the adapter without swap fee — set it AFTER the deposit cycle so only the withdraw
        // leg is haircut. Isolates the withdraw-side effect.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();
        eurVault.setHedgeSwapFeeBps(swapFeeBps);

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAndSweep();

        uint256 expectedPayout = (assets * (10_000 - swapFeeBps)) / 10_000;

        assertEq(eurc.balanceOf(address(adapter)), expectedPayout, "payout = gross * (1 - swapFee)");
        assertEq(eurc.balanceOf(address(eurVault)), assets - expectedPayout, "swap loss retained on EUR vault");
        // No outstanding bpEUR left; backing fully drained.
        assertEq(eurVault.totalEurcBacking(), 0, "backing drained by gross");
    }

    /// @notice Scenario 3: Composition of swap fee + protocol withdraw fee.
    ///         Adapter receives `(gross * (1 - swapFee)) * (1 - protoFee_ceil)`.
    function testSwapFeeAndWithdrawFeeCompose(uint256 assets, uint16 swapFeeBps, uint16 withdrawFeeBps) public {
        swapFeeBps = uint16(bound(swapFeeBps, 1, 500));
        withdrawFeeBps = uint16(bound(withdrawFeeBps, 1, 500));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();

        eurVault.setHedgeSwapFeeBps(swapFeeBps);
        eurVault.setWithdrawFeeBps(withdrawFeeBps);

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAndSweep();

        // Match the on-chain composition: swap (rounded down) → protocol fee (ceiling).
        uint256 afterSwap = (assets * (10_000 - swapFeeBps)) / 10_000;
        uint256 protoFee = (afterSwap * withdrawFeeBps + 9_999) / 10_000;
        uint256 expectedPayout = afterSwap - protoFee;

        assertEq(eurc.balanceOf(address(adapter)), expectedPayout, "payout = (gross * (1-swap)) - protoFee");
        // Vault retains swap loss + protocol fee on its EURC balance.
        assertEq(eurc.balanceOf(address(eurVault)), assets - expectedPayout, "vault retains swap loss + proto fee");
    }

    /// @notice Scenario 4: Withdraw fee deducted at settlement - gate-blocked
    ///         The post-fee EURC is parked as claimable (under the position) instead of being transferred.
    function testWithdrawFeeReducesClaimableEurc(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setWithdrawFeeBps(feeBps);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Gate-blocked: payout parked as claimable under the withdraw position, less the fee.
        _settleAdapterBatchToClaimable();

        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedClaimable = assets - expectedFee;

        address position = adapter.positions(0);
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter has no idle EURC");
        assertEq(eurVault.claimableEurc(position), expectedClaimable, "claimable = gross - fee");
        assertEq(eurc.balanceOf(address(eurVault)), assets, "vault holds fee + claimable on its balance");
        // The claimable payout is still counted by realAssets via the settled position.
        assertEq(adapter.realAssets(), expectedClaimable, "realAssets counts the position's claimable EURC");
    }

    /* PERMISSIONLESS sweepSettled */

    /// @notice The permissionless `sweepSettled` claims gate-blocked deposit shares from a settled
    ///         position and brings them home as live bpEUR on the adapter.
    function testSweepSettledPullsClaimableSharesHome(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed bpEUR via the gate-blocked deposit path so shares park as claimableShares under the
        // position, whose batch then settles + closes.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatchToClaimable();

        uint256 expectedShares = assets * BPEUR_PER_EURC;
        address position = adapter.positions(0);

        // Pre-state: full deposit sits as claimable shares under the settled position.
        assertEq(eurVault.claimableShares(position), expectedShares, "claimable == full deposit (no fees)");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "no live bpEUR before sweep");
        assertEq(adapter.positionsLength(), 1, "settled position still listed pre-sweep");

        // Permissionless: anyone may call
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.SweepPosition(position, expectedShares, 0);
        vm.prank(anyone);
        adapter.sweepSettled(type(uint256).max);

        assertEq(eurVault.balanceOf(address(adapter)), expectedShares, "shares swept to adapter");
        assertEq(eurVault.claimableShares(position), 0, "claimable drained");
        assertEq(adapter.positionsLength(), 0, "settled position dropped");
        assertEq(adapter.realAssets(), assets, "realAssets reflects the swept bpEUR position");
    }

    /// @notice The permissionless `sweepSettled` claims a gate-blocked withdraw payout from a settled
    ///         position and brings it home as idle EURC on the adapter.
    function testSweepSettledPullsClaimableEurcHome(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed bpEUR, then withdraw on the gate-blocked path so the payout parks as claimableEurc
        // under the withdraw position, whose batch then settles + closes.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable();

        address position = adapter.positions(0);

        // Pre-state: full payout sits as claimable (no fees) under the settled position.
        assertEq(eurVault.claimableEurc(position), assets, "claimable == full payout (no fees)");
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC before sweep");
        assertEq(adapter.positionsLength(), 1, "settled position still listed pre-sweep");

        // Permissionless: anyone may call
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.SweepPosition(position, 0, assets);
        vm.prank(anyone);
        adapter.sweepSettled(type(uint256).max);

        assertEq(eurc.balanceOf(address(adapter)), assets, "payout swept to adapter idle");
        assertEq(eurVault.claimableEurc(position), 0, "claimable drained");
        assertEq(adapter.positionsLength(), 0, "settled position dropped");
        assertEq(adapter.realAssets(), assets, "realAssets reflects the swept idle EURC");
    }

    /* sweep GUARDS (position clone) */

    /// @notice `EurVaultPosition.sweep` is adapter-gated: a direct call from any non-adapter address
    ///         reverts with `NotAdapter`. Only the adapter may pull a position's proceeds home — a third
    ///         party cannot redirect a clone's claim/transfer logic.
    function testSweepOnlyAdapter(address caller) public {
        vm.assume(caller != address(adapter));

        // Open a position through the adapter so we have a live clone to poke at.
        vault.deposit(100e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", 100e6);
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));

        // The `msg.sender == adapter` guard is checked first, so any non-adapter caller is rejected.
        vm.expectRevert(IEurVaultPosition.NotAdapter.selector);
        vm.prank(caller);
        position.sweep();
    }

    /// @notice `sweep` requires the position's batch to have closed: sweeping a still-pending position
    ///         reverts with `NotSettled` — even when the caller is the adapter itself. This is what stops
    ///         proceeds from being pulled home before settlement has actually credited them.
    function testSweepRevertsWhenNotSettled() public {
        // Open a deposit position but do NOT settle: its batch is still open, so settled() == false.
        vault.deposit(100e6, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", 100e6);
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertFalse(position.settled(), "position must still be pending");

        // Pass the `NotAdapter` guard by impersonating the adapter, then trip `NotSettled`.
        vm.expectRevert(IEurVaultPosition.NotSettled.selector);
        vm.prank(address(adapter));
        position.sweep();
    }
}
