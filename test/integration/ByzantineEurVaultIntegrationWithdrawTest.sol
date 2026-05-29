// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {ByzantineEurVaultAdapter} from "../../src/adapters/ByzantineEurVaultAdapter.sol";

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

        // Set up bpEUR on the adapter via the gate-open path so we can call requestWithdraw immediately.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();
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
        _settleAdapterBatch(); // gate-open: shares on adapter directly

        uint256 shares = eurVault.balanceOf(address(adapter));
        uint256 batchId = _activeBatchId();

        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Shares burned immediately.
        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares burned");
        // Pending withdraw recorded against the active batch.
        (,, uint256 pendingWith,, bool isOpen) = adapter.batchAccounting(batchId);
        assertEq(pendingWith, shares, "pendingWithdrawShares");
        assertTrue(isOpen, "batch should be open");
    }

    function testRequestWithdrawEmitsEvent(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        uint256 shares = eurVault.balanceOf(address(adapter));
        uint256 batchId = _activeBatchId();

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.RequestWithdraw(batchId, shares);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
    }

    function testRequestWithdrawPullsClaimableSharesFirst(uint256 assets) public {
        // Specifically tests the adapter's `_pullClaimableShares` invocation inside `requestWithdraw`:
        // when shares are gate-blocked into `claimableShares`, the adapter must pull them in before burning.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatchToClaimable(); // gate-blocked path: shares stay as claimable

        // Pre-state: nothing on adapter; everything sitting on the EUR vault as claimable.
        assertGt(eurVault.claimableShares(address(adapter)), 0, "should have claimable shares");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "no adapter shares before pull");

        uint256 claimable = eurVault.claimableShares(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(claimable); // adapter pulls then burns in one shot

        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares pulled and burned");
        assertEq(eurVault.claimableShares(address(adapter)), 0, "claimable shares drained");
    }

    function testRequestWithdrawRealAssetsPreservesValueBeforeAndAfterSettlement(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        uint256 realAssetsBefore = adapter.realAssets();
        uint256 shares = eurVault.balanceOf(address(adapter));

        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // realAssets must not change just from queuing a withdrawal (shares -> pendingWithdrawShares value).
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged on request");

        _settleAdapterBatch();
        // After settlement, the EURC is sitting idle on the adapter (gate-open path) - realAssets must still match.
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged on settlement");
    }

    /* WITHDRAW AND HEDGE SWAP FEES (4 SCENARIOS) */

    /// @notice Scenario 1: Withdraw fee deducted at settlement - gate-open: adapter receives `gross - fee`,
    ///         the fee EURC stays on the EUR vault.
    function testWithdrawFeeReducesPayoutByFeeBps(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000)); // up to 10%
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setWithdrawFeeBps(feeBps);

        // Seed the adapter with bpEUR via a normal deposit cycle (no deposit fee).
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        // Burn all of the adapter's bpEUR.
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Settle on the gate-open path: EURC routed directly to the adapter, less the fee.
        _settleAdapterBatch();

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
        _settleAdapterBatch();
        eurVault.setHedgeSwapFeeBps(swapFeeBps);

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatch();

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
        _settleAdapterBatch();

        eurVault.setHedgeSwapFeeBps(swapFeeBps);
        eurVault.setWithdrawFeeBps(withdrawFeeBps);

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatch();

        // Match the on-chain composition: swap (rounded down) → protocol fee (ceiling).
        uint256 afterSwap = (assets * (10_000 - swapFeeBps)) / 10_000;
        uint256 protoFee = (afterSwap * withdrawFeeBps + 9_999) / 10_000;
        uint256 expectedPayout = afterSwap - protoFee;

        assertEq(eurc.balanceOf(address(adapter)), expectedPayout, "payout = (gross * (1-swap)) - protoFee");
        // Vault retains swap loss + protocol fee on its EURC balance.
        assertEq(eurc.balanceOf(address(eurVault)), assets - expectedPayout, "vault retains swap loss + proto fee");
    }

    /// @notice Scenario 4: Withdraw fee deducted at settlement - gate-blocked
    ///         The post-fee EURC is parked as claimable on the EUR vault instead of being transferred.
    function testWithdrawFeeReducesClaimableEurc(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setWithdrawFeeBps(feeBps);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Gate-blocked: payout parked as claimable, less the fee.
        _settleAdapterBatchToClaimable();

        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedClaimable = assets - expectedFee;

        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter has no idle EURC");
        assertEq(eurVault.claimableEurc(address(adapter)), expectedClaimable, "claimable = gross - fee");
        assertEq(eurc.balanceOf(address(eurVault)), assets, "vault holds fee + claimable on its balance");
    }

    /* PERMISSIONLESS pullClaimableShares / pullClaimableEurc */

    /// @notice The permissionless `pullClaimableShares()` pulls gate-blocked deposit shares out
    ///         of the EUR vault onto the adapter as live bpEUR.
    function testPullClaimableSharesPullsDepositAndClearsSettledBatch(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed bpEUR via the gate-blocked deposit path so shares park as claimableShares and the deposit
        // batch settles + closes (leaving it listed in openBatchIds until the next clear).
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatchToClaimable();

        uint256 expectedShares = assets * BPEUR_PER_EURC;

        // Pre-state: full deposit sits as claimable shares; the settled deposit batch is still listed.
        assertEq(eurVault.claimableShares(address(adapter)), expectedShares, "claimable == full deposit (no fees)");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "no live bpEUR before pull");
        assertEq(adapter.openBatchIdsLength(), 1, "settled batch still listed pre-pull");

        // Permissionless: anyone may call
        address anyone = makeAddr("anyone");
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.PullClaimableShares(expectedShares);
        vm.prank(anyone);
        adapter.pullClaimableShares();

        assertEq(eurVault.balanceOf(address(adapter)), expectedShares, "shares pulled to adapter");
        assertEq(eurVault.claimableShares(address(adapter)), 0, "claimable drained");
        assertEq(adapter.openBatchIdsLength(), 0, "settled batch cleared as side-effect");
        assertEq(adapter.realAssets(), assets, "realAssets reflects the pulled bpEUR position");
    }

    /// @notice The permissionless `pullClaimableEurc()` pulls a gate-blocked withdraw payout out
    ///         of the EUR vault onto the adapter as idle EURC.
    function testPullClaimableEurcPullsPayoutAndClearsSettledBatch(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed bpEUR, then withdraw on the gate-blocked path so the payout parks as claimableEurc and the
        // withdraw batch settles + closes (leaving it listed in openBatchIds until the next clear).
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable();

        // Pre-state: full payout sits as claimable (no fees); the settled withdraw batch is still listed.
        assertEq(eurVault.claimableEurc(address(adapter)), assets, "claimable == full payout (no fees)");
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC before pull");
        assertEq(adapter.openBatchIdsLength(), 1, "settled batch still listed pre-pull");

        // Permissionless: anyone may call
        address anyone = makeAddr("anyone");
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.PullClaimableEurc(assets);
        vm.prank(anyone);
        adapter.pullClaimableEurc();

        assertEq(eurc.balanceOf(address(adapter)), assets, "payout pulled to adapter idle");
        assertEq(eurVault.claimableEurc(address(adapter)), 0, "claimable drained");
        assertEq(adapter.openBatchIdsLength(), 0, "settled batch cleared as side-effect");
        assertEq(adapter.realAssets(), assets, "realAssets reflects the pulled idle EURC");
    }
}
