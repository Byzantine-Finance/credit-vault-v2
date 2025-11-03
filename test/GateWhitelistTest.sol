// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.0;

import "./BaseTest.sol";
import "../src/gate/ReceiveAssetsGate.sol";
import "../src/gate/ReceiveSharesGate.sol";
import "../src/gate/SendAssetsGate.sol";
import "../src/gate/SendSharesGate.sol";
import "../src/gate/GateBase.sol";

contract Bundler3Mock {
    address private _initiator;

    constructor(address initiator_) {
        _initiator = initiator_;
    }

    function initiator() external view returns (address) {
        return _initiator;
    }
}

contract BundlerAdapterMock {
    IBundler3 private _bundler3;

    constructor(IBundler3 bundler3_) {
        _bundler3 = bundler3_;
    }

    function BUNDLER3() external view returns (IBundler3) {
        return _bundler3;
    }
}

contract GateWhitelistTest is BaseTest {
    ReceiveAssetsGate receiveAssetsGate;
    ReceiveSharesGate receiveSharesGate;
    SendAssetsGate sendAssetsGate;
    SendSharesGate sendSharesGate;
    address immutable gateOwner = makeAddr("gateOwner");

    function setUp() public override {
        super.setUp();
        receiveAssetsGate = new ReceiveAssetsGate(gateOwner);
        receiveSharesGate = new ReceiveSharesGate(gateOwner);
        sendAssetsGate = new SendAssetsGate(gateOwner);
        sendSharesGate = new SendSharesGate(gateOwner);
    }

    function testConstructor() public view {
        assertEq(receiveAssetsGate.owner(), gateOwner);
        assertEq(receiveSharesGate.owner(), gateOwner);
        assertEq(sendAssetsGate.owner(), gateOwner);
        assertEq(sendSharesGate.owner(), gateOwner);
    }

    function testOwnerOperations(address newOwner, address nonOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);

        // Non-owner cannot transfer ownership (test receiveAssetsGate as example)
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        receiveAssetsGate.transferOwnership(newOwner);

        // Owner can transfer ownership (test all gates)
        vm.prank(gateOwner);
        receiveAssetsGate.transferOwnership(newOwner);
        vm.prank(newOwner);
        receiveAssetsGate.acceptOwnership();
        assertEq(receiveAssetsGate.owner(), newOwner);

        vm.prank(gateOwner);
        receiveSharesGate.transferOwnership(newOwner);
        vm.prank(newOwner);
        receiveSharesGate.acceptOwnership();
        assertEq(receiveSharesGate.owner(), newOwner);

        vm.prank(gateOwner);
        sendAssetsGate.transferOwnership(newOwner);
        vm.prank(newOwner);
        sendAssetsGate.acceptOwnership();
        assertEq(sendAssetsGate.owner(), newOwner);

        vm.prank(gateOwner);
        sendSharesGate.transferOwnership(newOwner);
        vm.prank(newOwner);
        sendSharesGate.acceptOwnership();
        assertEq(sendSharesGate.owner(), newOwner);
    }

    function testWhitelistOperations(address account, bool isWhitelisted, address nonOwner) public {
        vm.assume(account != address(0));
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);
        vm.assume(isWhitelisted == true); // Can only set to true to avoid AlreadySet error

        // Non-owner cannot whitelist
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        receiveAssetsGate.setIsWhitelisted(account, isWhitelisted);

        // Owner can whitelist (test all gates)
        // Test ReceiveAssetsGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsWhitelisted(account, isWhitelisted);
        receiveAssetsGate.setIsWhitelisted(account, isWhitelisted);
        assertEq(receiveAssetsGate.whitelisted(account), isWhitelisted);
        assertEq(receiveAssetsGate.canReceiveAssets(account), isWhitelisted);

        // Test ReceiveSharesGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsWhitelisted(account, isWhitelisted);
        receiveSharesGate.setIsWhitelisted(account, isWhitelisted);
        assertEq(receiveSharesGate.whitelisted(account), isWhitelisted);
        assertEq(receiveSharesGate.canReceiveShares(account), isWhitelisted);

        // Test SendAssetsGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsWhitelisted(account, isWhitelisted);
        sendAssetsGate.setIsWhitelisted(account, isWhitelisted);
        assertEq(sendAssetsGate.whitelisted(account), isWhitelisted);
        assertEq(sendAssetsGate.canSendAssets(account), isWhitelisted);

        // Test SendSharesGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsWhitelisted(account, isWhitelisted);
        sendSharesGate.setIsWhitelisted(account, isWhitelisted);
        assertEq(sendSharesGate.whitelisted(account), isWhitelisted);
        assertEq(sendSharesGate.canSendShares(account), isWhitelisted);
    }

    function testSetIsWhitelistedBatch(uint8 arrayLength, address nonOwner) public {
        vm.assume(arrayLength > 0 && arrayLength <= 10);
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);

        address[] memory accounts = new address[](arrayLength);
        bool[] memory isWhitelistedArray = new bool[](arrayLength);

        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = makeAddr(string(abi.encodePacked("account", vm.toString(i))));
            isWhitelistedArray[i] = true; // Set all to true to avoid AlreadySet error
        }

        // Non-owner cannot whitelist batch (test receiveAssetsGate as example)
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        receiveAssetsGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);

        // Owner can whitelist batch
        vm.prank(gateOwner);
        for (uint256 i; i < accounts.length; ++i) {
            vm.expectEmit(true, true, true, true);
            emit GateBase.SetIsWhitelisted(accounts[i], isWhitelistedArray[i]);
        }
        receiveAssetsGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);

        // Verify that all accounts have been correctly updated
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(receiveAssetsGate.whitelisted(accounts[i]), isWhitelistedArray[i]);
            assertEq(receiveAssetsGate.canReceiveAssets(accounts[i]), isWhitelistedArray[i]);
        }

        // Test ReceiveSharesGate
        vm.prank(gateOwner);
        receiveSharesGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(receiveSharesGate.whitelisted(accounts[i]), isWhitelistedArray[i]);
            assertEq(receiveSharesGate.canReceiveShares(accounts[i]), isWhitelistedArray[i]);
        }

        // Test SendAssetsGate
        vm.prank(gateOwner);
        sendAssetsGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(sendAssetsGate.whitelisted(accounts[i]), isWhitelistedArray[i]);
            assertEq(sendAssetsGate.canSendAssets(accounts[i]), isWhitelistedArray[i]);
        }

        // Test SendSharesGate
        vm.prank(gateOwner);
        sendSharesGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(sendSharesGate.whitelisted(accounts[i]), isWhitelistedArray[i]);
            assertEq(sendSharesGate.canSendShares(accounts[i]), isWhitelistedArray[i]);
        }
    }

    function testSetIsWhitelistedBatchArrayLengthMismatch(address[] memory accounts, bool[] memory isWhitelistedArray)
        public
    {
        vm.assume(accounts.length != isWhitelistedArray.length);
        vm.assume(accounts.length > 0);
        vm.assume(isWhitelistedArray.length > 0);

        // Test ReceiveAssetsGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        receiveAssetsGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);

        // Test ReceiveSharesGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        receiveSharesGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);

        // Test SendAssetsGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        sendAssetsGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);

        // Test SendSharesGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        sendSharesGate.setIsWhitelistedBatch(accounts, isWhitelistedArray);
    }

    function testSetIsWhitelistedAlreadySet(address account, bool isWhitelisted) public {
        vm.assume(account != address(0));
        vm.assume(isWhitelisted == false); // Can only set to false to test AlreadySet error

        // Test ReceiveAssetsGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        receiveAssetsGate.setIsWhitelisted(account, isWhitelisted);

        // Test ReceiveSharesGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        receiveSharesGate.setIsWhitelisted(account, isWhitelisted);

        // Test SendAssetsGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        sendAssetsGate.setIsWhitelisted(account, isWhitelisted);

        // Test SendSharesGate
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("AlreadySet()"));
        sendSharesGate.setIsWhitelisted(account, isWhitelisted);
    }

    function testBundlerAdapterOperations(address bundlerAdapterAddr, bool isAdapter, address nonOwner) public {
        vm.assume(bundlerAdapterAddr != address(0));
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);

        // Non-owner cannot set bundler adapter
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        receiveAssetsGate.setIsBundlerAdapter(bundlerAdapterAddr, isAdapter);

        // Owner can set bundler adapter (test all gates)
        // Test ReceiveAssetsGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        receiveAssetsGate.setIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        assertEq(receiveAssetsGate.isBundlerAdapter(bundlerAdapterAddr), isAdapter);

        // Test ReceiveSharesGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        receiveSharesGate.setIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        assertEq(receiveSharesGate.isBundlerAdapter(bundlerAdapterAddr), isAdapter);

        // Test SendAssetsGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        sendAssetsGate.setIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        assertEq(sendAssetsGate.isBundlerAdapter(bundlerAdapterAddr), isAdapter);

        // Test SendSharesGate
        vm.prank(gateOwner);
        vm.expectEmit(true, true, true, true);
        emit GateBase.SetIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        sendSharesGate.setIsBundlerAdapter(bundlerAdapterAddr, isAdapter);
        assertEq(sendSharesGate.isBundlerAdapter(bundlerAdapterAddr), isAdapter);
    }

    function testAdapterWithWhitelistedInitiator(address initiatorAddr, bool isWhitelisted) public {
        vm.assume(initiatorAddr != address(0));
        vm.assume(isWhitelisted == true); // Can only test setting to true initially

        // Create a new bundler and adapter for the test
        address bundlerAddr = address(new Bundler3Mock(initiatorAddr));
        address bundlerAdapterAddr = address(new BundlerAdapterMock(IBundler3(bundlerAddr)));

        // Test ReceiveAssetsGate
        vm.prank(gateOwner);
        receiveAssetsGate.setIsWhitelisted(initiatorAddr, isWhitelisted);

        // Test when bundler adapter is not registered
        assertFalse(receiveAssetsGate.canReceiveAssets(bundlerAdapterAddr));

        // Test when bundler adapter is registered
        vm.prank(gateOwner);
        receiveAssetsGate.setIsBundlerAdapter(bundlerAdapterAddr, true);
        assertEq(receiveAssetsGate.canReceiveAssets(bundlerAdapterAddr), isWhitelisted);

        // Unwhitelist initiator
        vm.prank(gateOwner);
        receiveAssetsGate.setIsWhitelisted(initiatorAddr, false);
        assertFalse(receiveAssetsGate.canReceiveAssets(bundlerAdapterAddr));

        // Test ReceiveSharesGate
        vm.prank(gateOwner);
        receiveSharesGate.setIsWhitelisted(initiatorAddr, isWhitelisted);
        assertFalse(receiveSharesGate.canReceiveShares(bundlerAdapterAddr));

        vm.prank(gateOwner);
        receiveSharesGate.setIsBundlerAdapter(bundlerAdapterAddr, true);
        assertEq(receiveSharesGate.canReceiveShares(bundlerAdapterAddr), isWhitelisted);

        vm.prank(gateOwner);
        receiveSharesGate.setIsWhitelisted(initiatorAddr, false);
        assertFalse(receiveSharesGate.canReceiveShares(bundlerAdapterAddr));

        // Test SendAssetsGate
        vm.prank(gateOwner);
        sendAssetsGate.setIsWhitelisted(initiatorAddr, isWhitelisted);
        assertFalse(sendAssetsGate.canSendAssets(bundlerAdapterAddr));

        vm.prank(gateOwner);
        sendAssetsGate.setIsBundlerAdapter(bundlerAdapterAddr, true);
        assertEq(sendAssetsGate.canSendAssets(bundlerAdapterAddr), isWhitelisted);

        vm.prank(gateOwner);
        sendAssetsGate.setIsWhitelisted(initiatorAddr, false);
        assertFalse(sendAssetsGate.canSendAssets(bundlerAdapterAddr));

        // Test SendSharesGate
        vm.prank(gateOwner);
        sendSharesGate.setIsWhitelisted(initiatorAddr, isWhitelisted);
        assertFalse(sendSharesGate.canSendShares(bundlerAdapterAddr));

        vm.prank(gateOwner);
        sendSharesGate.setIsBundlerAdapter(bundlerAdapterAddr, true);
        assertEq(sendSharesGate.canSendShares(bundlerAdapterAddr), isWhitelisted);

        vm.prank(gateOwner);
        sendSharesGate.setIsWhitelisted(initiatorAddr, false);
        assertFalse(sendSharesGate.canSendShares(bundlerAdapterAddr));
    }

    function testRenounceOwnershipNotAllowed() public {
        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("NotAllowedToRenounceOwnership()"));
        receiveAssetsGate.renounceOwnership();
        assertEq(receiveAssetsGate.owner(), gateOwner);

        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("NotAllowedToRenounceOwnership()"));
        receiveSharesGate.renounceOwnership();
        assertEq(receiveSharesGate.owner(), gateOwner);

        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("NotAllowedToRenounceOwnership()"));
        sendAssetsGate.renounceOwnership();
        assertEq(sendAssetsGate.owner(), gateOwner);

        vm.prank(gateOwner);
        vm.expectRevert(abi.encodeWithSignature("NotAllowedToRenounceOwnership()"));
        sendSharesGate.renounceOwnership();
        assertEq(sendSharesGate.owner(), gateOwner);
    }
}
