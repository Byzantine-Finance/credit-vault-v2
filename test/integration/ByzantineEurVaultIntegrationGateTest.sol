// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {GateWhitelist} from "../../src/gate/GateWhitelist.sol";
import {ReceiveSharesGate} from "../../src/gate/ReceiveSharesGate.sol";
import {GateBase} from "../../src/gate/GateBase.sol";
import {Clones} from "../../lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @notice Trusted-cloner flow: the adapter reads the active gates live from the EUR vault and
///         auto-whitelists every freshly cloned position on them. The gates only accept addresses
///         they can re-derive themselves (CREATE2: registered implementation + salt + deployer ==
///         caller).
contract ByzantineEurVaultIntegrationGateTest is ByzantineEurVaultIntegrationTest {
    uint256 internal constant ASSETS_100 = 100e6;

    address internal immutable gateOwner = makeAddr("gateOwner");

    GateWhitelist internal gateWhitelist; // standalone all-in-one gate, serves 3 roles (exercises dedupe)
    ReceiveSharesGate internal receiveSharesGate; // GateBase-derived gate, serves the receive-shares role

    function setUp() public override {
        super.setUp();

        gateWhitelist = new GateWhitelist(gateOwner);
        receiveSharesGate = new ReceiveSharesGate(gateOwner);

        // The gate owners register the adapter as a trusted cloner of its position implementation,
        // and whitelist the adapter itself (it receives the sweeps / claims and sends shares to
        // fresh withdraw positions — like any regular account, it must pass the gates).
        address implementation = adapter.positionImplementation();
        vm.startPrank(gateOwner);
        gateWhitelist.setClonerImplementation(address(adapter), implementation);
        receiveSharesGate.setClonerImplementation(address(adapter), implementation);
        gateWhitelist.setIsWhitelisted(address(adapter), true);
        receiveSharesGate.setIsWhitelisted(address(adapter), true);
        vm.stopPrank();

        // Gates are wired on the EUR VAULT (single source of truth); the adapter reads them live.
        // The same GateWhitelist serves three roles, so the adapter's dedupe path is exercised on
        // every position creation.
        eurVault.setGates(
            address(receiveSharesGate), address(gateWhitelist), address(gateWhitelist), address(gateWhitelist)
        );
    }

    /* AUTO-WHITELISTING ON POSITION CREATION */

    /// @notice `allocate` whitelists the fresh deposit position on every active EUR-vault gate,
    ///         deduplicated (the GateWhitelist serves 3 roles but is called once).
    function testAllocateWhitelistsPositionOnAllActiveGates() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        address position = adapter.positions(0);
        assertTrue(gateWhitelist.whitelisted(position), "position whitelisted on GateWhitelist");
        assertTrue(receiveSharesGate.whitelisted(position), "position whitelisted on ReceiveSharesGate");
        assertTrue(gateWhitelist.canReceiveShares(position), "gate check passes for the position");
        assertTrue(receiveSharesGate.canReceiveShares(position), "gate check passes for the position");
    }

    /// @notice `requestWithdraw` whitelists the fresh withdraw position too.
    function testRequestWithdrawWhitelistsPosition() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAndSweep();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        address position = adapter.positions(0);
        assertTrue(gateWhitelist.whitelisted(position), "withdraw position whitelisted");
        assertTrue(receiveSharesGate.whitelisted(position), "withdraw position whitelisted (GateBase gate)");
    }

    /// @notice The whitelisted address is exactly the deployed clone: the gate re-derives it from
    ///         CREATE2 instead of trusting the caller's word.
    function testWhitelistCloneReturnsDeployedCloneAddress() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        // The position was created with salt = nonce 0; re-derive it the way the gate does.
        address derived =
            Clones.predictDeterministicAddress(adapter.positionImplementation(), bytes32(uint256(0)), address(adapter));
        assertEq(derived, adapter.positions(0), "derived CREATE2 address == deployed clone");
    }

    /// @notice A gate rotation on the EUR vault is picked up automatically by the adapter: the next
    ///         position is whitelisted on the NEW gate without any adapter reconfiguration.
    function testGateRotationOnEurVaultIsPickedUpAutomatically() public {
        // First position under the initial gates.
        vault.deposit(ASSETS_100 * 2, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        address position1 = adapter.positions(0);
        assertTrue(gateWhitelist.whitelisted(position1), "position1 on the old gate");

        // Settle + sweep so the next allocate opens a fresh position in a new batch.
        // (Aggregation into a pre-rotation position would instead need the existing position to be
        // re-whitelisted on the new gate by the gate owner — see the gate-rotation operational notes.)
        _settleAndSweep();

        // Governance rotates the gates on the EUR vault — nothing is touched on the adapter.
        GateWhitelist newGate = new GateWhitelist(gateOwner);
        address implementation = adapter.positionImplementation();
        vm.prank(gateOwner);
        newGate.setClonerImplementation(address(adapter), implementation);
        eurVault.setGates(address(newGate), address(newGate), address(newGate), address(newGate));

        // A new batch's position is whitelisted on the NEW gate automatically.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        address position2 = adapter.positions(adapter.positionsLength() - 1);
        assertTrue(newGate.whitelisted(position2), "position2 whitelisted on the new gate");
        assertFalse(gateWhitelist.whitelisted(position2), "position2 not on the old gate");
    }

    /* TRUST BOUNDARIES */

    /// @notice An address that was never registered as a trusted cloner cannot whitelist anything.
    function testSetIsCloneWhitelistedRevertsForUntrustedCaller(address untrusted, bytes32 salt) public {
        vm.assume(untrusted != address(adapter));

        vm.expectRevert(GateWhitelist.NotTrustedCloner.selector);
        vm.prank(untrusted);
        gateWhitelist.setIsCloneWhitelisted(salt, true);

        vm.expectRevert(GateBase.NotTrustedCloner.selector);
        vm.prank(untrusted);
        receiveSharesGate.setIsCloneWhitelisted(salt, true);
    }

    /// @notice A trusted cloner can only whitelist clones it deployed ITSELF: the derivation binds
    ///         `deployer == msg.sender`, so the same salt from another trusted account yields a
    ///         different (their own) address — never the adapter's clone.
    function testSetIsCloneWhitelistedIsBoundToCallerAsDeployer() public {
        address otherCloner = makeAddr("otherCloner");
        address implementation = adapter.positionImplementation();
        vm.prank(gateOwner);
        gateWhitelist.setClonerImplementation(otherCloner, implementation);

        vm.prank(otherCloner);
        address whitelistedByOther = gateWhitelist.setIsCloneWhitelisted(bytes32(uint256(0)), true);

        address adapterClone =
            Clones.predictDeterministicAddress(adapter.positionImplementation(), bytes32(uint256(0)), address(adapter));
        assertTrue(whitelistedByOther != adapterClone, "same salt, different deployer => different address");
        assertFalse(gateWhitelist.whitelisted(adapterClone), "the adapter's clone is NOT whitelisted");
    }

    /// @notice The trusted cloner can remove one of its clones from the whitelist by salt, and the
    ///         gate owner can always remove it by address via `setIsWhitelisted` (a clone is a plain
    ///         account).
    function testCloneCanBeRemovedFromWhitelist(bytes32 salt) public {
        address implementation = adapter.positionImplementation();
        vm.startPrank(gateOwner);
        gateWhitelist.setClonerImplementation(address(this), implementation);
        receiveSharesGate.setClonerImplementation(address(this), implementation);
        vm.stopPrank();

        // Cloner-side removal by salt, on both gate variants.
        address clone = gateWhitelist.setIsCloneWhitelisted(salt, true);
        gateWhitelist.setIsCloneWhitelisted(salt, false);
        assertFalse(gateWhitelist.whitelisted(clone), "cloner removed its clone by salt (GateWhitelist)");

        receiveSharesGate.setIsCloneWhitelisted(salt, true);
        receiveSharesGate.setIsCloneWhitelisted(salt, false);
        assertFalse(receiveSharesGate.whitelisted(clone), "cloner removed its clone by salt (GateBase)");

        // Owner-side removal by address.
        gateWhitelist.setIsCloneWhitelisted(salt, true);
        vm.prank(gateOwner);
        gateWhitelist.setIsWhitelisted(clone, false);
        assertFalse(gateWhitelist.whitelisted(clone), "owner removed the clone by address");
    }

    /// @notice `setIsCloneWhitelisted` is NOT idempotent on the GateBase variant (`AlreadySet` on an
    ///         unchanged status) — this documents why the adapter deduplicates the gates it calls.
    function testDuplicateSetRevertsOnGateBaseVariant(bytes32 salt) public {
        address implementation = adapter.positionImplementation();
        vm.prank(gateOwner);
        receiveSharesGate.setClonerImplementation(address(this), implementation);

        receiveSharesGate.setIsCloneWhitelisted(salt, true);
        vm.expectRevert(GateBase.AlreadySet.selector);
        receiveSharesGate.setIsCloneWhitelisted(salt, true);
    }

    /// @notice Revoking the adapter's trusted-cloner status makes position creation revert: while
    ///         a gate is active on the EUR vault, its trust registration is a hard dependency.
    function testAllocateRevertsWhenClonerTrustRevoked() public {
        vm.prank(gateOwner);
        gateWhitelist.setClonerImplementation(address(adapter), address(0));

        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vm.expectRevert(GateWhitelist.NotTrustedCloner.selector);
        vault.allocate(address(adapter), hex"", ASSETS_100);
    }

    /// @notice With a gateless EUR vault (all gates `address(0)`, the default of the rest of the
    ///         test suite), position creation performs no gate call at all.
    function testGatelessEurVaultSkipsWhitelisting() public {
        eurVault.setGates(address(0), address(0), address(0), address(0));

        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);

        assertFalse(gateWhitelist.whitelisted(adapter.positions(0)), "no gate call on a gateless EUR vault");
        assertEq(adapter.realAssets(), ASSETS_100, "position works without gates");
    }

    /// @notice The mock enforces the gates like the real vault: a non-whitelisted account cannot
    ///         request, while the adapter's auto-whitelisted clones can (proven by every other test
    ///         of this suite running with enforcement on).
    function testRequestRevertsForNonWhitelistedUser() public {
        address rando = makeAddr("rando");
        deal(address(eurc), rando, ASSETS_100);
        vm.startPrank(rando);
        eurc.approve(address(eurVault), type(uint256).max);
        vm.expectRevert(MockByzantinePrimeEURVault.SendAssetsBlocked.selector);
        eurVault.requestDeposit(ASSETS_100, rando);
        vm.stopPrank();
    }

    /* FULL LIFECYCLE WITH GATES */

    /// @notice End-to-end: allocate -> settle -> sweep -> withdraw -> settle -> deallocate, with the
    ///         gates wired the whole way. Every position created along the way is auto-whitelisted.
    function testFullCycleWithGatesWired() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        address depositPosition = adapter.positions(0);
        _settleAndSweep();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        address withdrawPosition = adapter.positions(0);
        _settleAdapterBatch();

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", ASSETS_100);

        assertTrue(gateWhitelist.whitelisted(depositPosition), "deposit position whitelisted");
        assertTrue(gateWhitelist.whitelisted(withdrawPosition), "withdraw position whitelisted");
        assertTrue(receiveSharesGate.whitelisted(depositPosition), "deposit position whitelisted (GateBase gate)");
        assertTrue(receiveSharesGate.whitelisted(withdrawPosition), "withdraw position whitelisted (GateBase gate)");
        assertEq(eurc.balanceOf(address(vault)), ASSETS_100, "full round-trip back to the parent vault");
        assertEq(adapter.positionsLength(), 0, "all positions swept");
    }
}
