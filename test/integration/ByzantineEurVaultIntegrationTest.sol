// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import {VaultV2Factory, IVaultV2Factory} from "../../src/VaultV2Factory.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import "../../src/libraries/ConstantsLib.sol";

import {ByzantineEurVaultAdapter} from "../../src/adapters/ByzantineEurVaultAdapter.sol";
import {ByzantineEurVaultAdapterFactory} from "../../src/adapters/ByzantineEurVaultAdapterFactory.sol";
import {IByzantineEurVaultAdapter} from "../../src/adapters/interfaces/IByzantineEurVaultAdapter.sol";
import {IByzantineEurVaultAdapterFactory} from "../../src/adapters/interfaces/IByzantineEurVaultAdapterFactory.sol";
import {IByzantinePrimeEURVault} from "../../src/interfaces/IByzantinePrimeEURVault.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockByzantinePrimeEURVault} from "../mocks/MockByzantinePrimeEURVault.sol";

import {Test, console2} from "../../lib/forge-std/src/Test.sol";

contract ByzantineEurVaultIntegrationTest is Test {
    uint256 internal constant MIN_TEST_ASSETS = 10;
    uint256 internal constant MAX_TEST_ASSETS = 1e24;

    // EURC mock decimals
    uint8 internal constant EURC_DECIMALS = 6;

    /// @dev Scale factor between bpEUR (18 decimals) and EURC (6 decimals). At parity, 1 raw EURC mints
    ///      `BPEUR_PER_EURC` raw bpEUR. Matches the real vault's `ONE_SHARE / ONE_STABLE` ratio.
    uint256 internal constant BPEUR_PER_EURC = 1e12;

    // Test accounts
    address internal immutable owner = makeAddr("owner");
    address internal immutable curator = makeAddr("curator");
    address internal immutable adapterCurator = makeAddr("adapterCurator");
    address internal immutable allocator = makeAddr("allocator");
    address internal immutable sentinel = makeAddr("sentinel");
    address internal immutable receiver = makeAddr("receiver");
    address internal immutable skimRecipient = makeAddr("skimRecipient");

    // Expected adapter id data
    bytes32 internal expectedAdapterId;
    bytes internal expectedAdapterIdData;

    // Contracts
    ERC20Mock internal eurc;
    MockByzantinePrimeEURVault internal eurVault;
    IVaultV2Factory internal vaultFactory;
    IVaultV2 internal vault;
    IByzantineEurVaultAdapterFactory internal adapterFactory;
    ByzantineEurVaultAdapter internal adapter;

    function setUp() public virtual {
        vm.label(address(this), "testContract");

        // EURC
        eurc = new ERC20Mock(EURC_DECIMALS);
        vm.label(address(eurc), "EURC");

        // EUR vault with 0 deposit fee by default
        eurVault = new MockByzantinePrimeEURVault(address(eurc), 0);
        vm.label(address(eurVault), "bpEUR");

        /* VAULT SETUP */

        vaultFactory = IVaultV2Factory(address(new VaultV2Factory()));
        vault = IVaultV2(vaultFactory.createVaultV2(owner, address(eurc), bytes32(0)));
        vm.label(address(vault), "vault");

        adapterFactory = IByzantineEurVaultAdapterFactory(address(new ByzantineEurVaultAdapterFactory()));
        adapter =
            ByzantineEurVaultAdapter(adapterFactory.createByzantineEurVaultAdapter(address(vault), address(eurVault)));
        expectedAdapterIdData = abi.encode("this", address(adapter));
        expectedAdapterId = keccak256(expectedAdapterIdData);
        vm.label(address(adapter), "adapter");

        // Wire vault roles & adapter.
        vm.startPrank(owner);
        vault.setCurator(curator);
        vault.setIsSentinel(sentinel, true);
        vm.stopPrank();

        vm.startPrank(curator);

        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);

        vault.submit(abi.encodeCall(IVaultV2.addAdapter, address(adapter)));
        vault.addAdapter(address(adapter));

        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (expectedAdapterIdData, type(uint128).max)));
        vault.increaseAbsoluteCap(expectedAdapterIdData, type(uint128).max);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (expectedAdapterIdData, WAD)));
        vault.increaseRelativeCap(expectedAdapterIdData, WAD);

        // Vault curator assigns the adapter curator role on the adapter.
        adapter.setAdapterCurator(adapterCurator);

        vm.stopPrank();

        // max rate so interest accrual does not cap totalAssets in tests
        vm.prank(allocator);
        vault.setMaxRate(MAX_MAX_RATE);

        // Fund the test contract with EURC and approve the vault.
        deal(address(eurc), address(this), MAX_TEST_ASSETS);
        eurc.approve(address(vault), type(uint256).max);
    }

    /* HELPERS */

    /// @dev Gate-open path: Composes the two-phase finalize primitives into one call that settles the active EUR-vault
    ///      batch for the adapter only.
    /// @dev Use this when the test does NOT need to observe claimable state.
    function _settleAdapterBatch() internal {
        address[] memory r = new address[](1);
        r[0] = address(adapter);
        eurVault.executeDnt();
        eurVault.processDepositChunk(r, type(uint256).max);
        eurVault.processWithdrawChunk(r, type(uint256).max);
        eurVault.closeBatch();
    }

    /// @dev Gate-blocked path: Same as `_settleAdapterBatch` but flips both gate flags to set the gate-blocked path
    ///      so settlement routes via `claimableShares` / `claimableEurc`.
    /// @dev Use this when the test needs to exercise the adapter's `_pullClaimableShares` / `_pullClaimableEurc` paths.
    function _settleAdapterBatchToClaimable() internal {
        // Flip the gate flags to the gate-blocked path
        eurVault.setReceiveSharesBlocked(true);
        eurVault.setReceiveAssetsBlocked(true);
        _settleAdapterBatch();
        // Reset the gate flags to the default (gate-open)
        eurVault.setReceiveSharesBlocked(false);
        eurVault.setReceiveAssetsBlocked(false);
    }

    /// @dev Returns the batchId that will be used by the adapter on the next `allocate` / `requestWithdraw`.
    function _activeBatchId() internal view returns (uint256) {
        return eurVault.vaultState() == IByzantinePrimeEURVault.VaultState.NormalIdle
            ? eurVault.currentBatchId()
            : eurVault.nextBatchId();
    }

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        return vault.deposit(assets, address(this));
    }
}
