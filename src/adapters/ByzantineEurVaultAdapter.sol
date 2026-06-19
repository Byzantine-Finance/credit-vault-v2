// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {IByzantinePrimeEURVault} from "../interfaces/IByzantinePrimeEURVault.sol";
import {IByzantineEurVaultAdapter} from "./interfaces/IByzantineEurVaultAdapter.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {EurVaultPosition} from "./EurVaultPosition.sol";
import {IEurVaultPosition} from "./interfaces/IEurVaultPosition.sol";
import {Clones} from "../../lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ICloneWhitelistGate} from "../interfaces/IGate.sol";

/// @dev Every ByzantineEURVault request (deposit or withdraw) is isolated in its own `EurVaultPosition`
///      minimal-proxy clone, which is the owner and receiver of its single ticket. Settlement
///      detection is close-based (`currentBatchId() > position.batchId`) and `realAssets()` reads each
///      position in isolation.
contract ByzantineEurVaultAdapter is IByzantineEurVaultAdapter {
    /* IMMUTABLES */

    address public immutable factory;
    address public immutable parentVault;
    address public immutable eurVault;
    address public immutable asset;
    bytes32 public immutable adapterId;
    address public immutable positionImplementation;

    /* STORAGE */

    address public skimRecipient;
    address public adapterCurator;

    /// @dev Live positions (not yet swept). Settled ones are swept and removed by `_sweepSettled`.
    address[] public positions;

    /// @dev Open batch id => address of the clone aggregating that batch's deposits.
    mapping(uint256 batchId => address) public depositPositionOf;

    /// @dev Open batch id => address of the clone aggregating that batch's withdrawals.
    mapping(uint256 batchId => address) public withdrawPositionOf;

    /// @dev CREATE2 salt counter, so position addresses are predictable
    uint256 public positionNonce;

    /* CONSTRUCTOR */

    constructor(address _parentVault, address _eurVault) {
        factory = msg.sender;
        parentVault = _parentVault;
        eurVault = _eurVault;
        asset = IVaultV2(_parentVault).asset();
        require(asset == IByzantinePrimeEURVault(_eurVault).asset(), AssetMismatch());
        adapterId = keccak256(abi.encode("this", address(this)));
        positionImplementation = address(new EurVaultPosition(_eurVault, asset));
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS */

    /// @dev Allocates `assets` to the adapter and opens a deposit position on the EUR vault.
    /// @dev Assets are transferred immediately to the EUR vault while bpEUR shares are minted to the
    ///      position contract at the next DNT settlement.
    function allocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256) {
        require(msg.sender == parentVault, NotAuthorized());
        require(data.length == 0, InvalidData());

        // Sweep settled positions home before opening a new one.
        _sweepSettled(type(uint256).max);

        if (assets != 0) {
            (address position, uint256 batchId, uint256 netAssets) = _routeDeposit(assets);
            emit Allocate(position, batchId, assets, netAssets);
        }

        uint256 oldAllocation = allocation();
        uint256 newAllocation = _realAssets();

        // forge-lint: disable-next-item(unsafe-typecast) safe because ByzantinePrimeEURVault's position
        // is bounded by EURC's total supply, and allocation is less than the max total assets of the vault.
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @dev Allows deallocation only if the adapter has enough idle EURC (after sweeping settled positions home).
    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory, int256)
    {
        require(msg.sender == parentVault, NotAuthorized());
        require(data.length == 0, InvalidData());

        // Sweep settled positions so their EURC proceeds are available for the deallocation.
        _sweepSettled(type(uint256).max);

        // Only allowed to deallocate if the adapter has enough idle EURC
        require(IERC20(asset).balanceOf(address(this)) >= assets, InsufficientIdle());

        // Reflects the post-transfer state: current realAssets minus the assets VaultV2 is about to pull
        uint256 oldAllocation = allocation();
        uint256 newAllocation = _realAssets() - assets;

        emit Deallocate(assets);

        // forge-lint: disable-next-item(unsafe-typecast) safe because ByzantinePrimeEURVault's position
        // is bounded by EURC's total supply, and allocation is less than the max total assets of the vault.
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @dev Callable by adapter curator only.
    /// @dev Deposits `assets` of idle EURC held by the adapter into the EUR vault to earn yield.
    ///      The EURC leaves the adapter immediately while bpEUR shares are minted to the position contract at
    ///      the next DNT settlement.
    function requestDeposit(uint256 assets) external {
        require(msg.sender == adapterCurator, NotAuthorized());

        // Sweep settled positions so their EURC proceeds can be redeployed in this deposit.
        _sweepSettled(type(uint256).max);

        // Only allowed to deposit if the adapter has enough idle EURC
        require(IERC20(asset).balanceOf(address(this)) >= assets, InsufficientIdle());

        (address position, uint256 batchId, uint256 netAssets) = _routeDeposit(assets);

        emit RequestDeposit(position, batchId, assets, netAssets);
    }

    /// @dev Callable by adapter curator only.
    /// @dev bpEUR shares are burned immediately while withdrawn assets are transferred to the position contract
    ///      at the next DNT settlement.
    function requestWithdraw(uint256 shares) external {
        require(msg.sender == adapterCurator, NotAuthorized());

        // Sweep settled positions so their bpEUR proceeds can be included in this withdrawal.
        _sweepSettled(type(uint256).max);

        // Only allowed to withdraw shares the adapter actually holds
        require(IERC20(eurVault).balanceOf(address(this)) >= shares, InsufficientShares());

        (address position, uint256 batchId) = _routeWithdraw(shares);

        emit RequestWithdraw(position, batchId, shares);
    }

    function setAdapterCurator(address newAdapterCurator) external {
        require(msg.sender == IVaultV2(parentVault).curator(), NotAuthorized());
        adapterCurator = newAdapterCurator;
        emit SetAdapterCurator(newAdapterCurator);
    }

    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == IVaultV2(parentVault).owner(), NotAuthorized());
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @dev Skims the adapter's balance of `token` and sends it to `skimRecipient`.
    /// @dev This is useful to handle rewards that the adapter has earned.
    function skim(address token) external {
        require(msg.sender == skimRecipient, NotAuthorized());
        require(token != asset, CannotSkimEurc());
        require(token != eurVault, CannotSkimBpEur());
        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, skimRecipient, balance);
        emit Skim(token, balance);
    }

    /* PERMISSIONLESS FUNCTIONS */

    /// @dev Sweeps settled positions back to the adapter. Permissionless: proceeds can only move
    ///      from a position to the adapter.
    /// @param maxPositions Bounds the loop so the call cannot run out of gas when many positions
    ///        are settled; pass `type(uint256).max` to sweep everything.
    function sweepSettled(uint256 maxPositions) external {
        _sweepSettled(maxPositions);
    }

    /* VIEWS */

    /// @dev Returns the adapter's ids
    function ids() public view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](1);
        ids_[0] = adapterId;
    }

    /// @dev Returns the adapter's allocation
    function allocation() public view returns (uint256) {
        return IVaultV2(parentVault).allocation(adapterId);
    }

    /// @dev Returns the adapter's real assets
    function realAssets() external view returns (uint256) {
        return _realAssets();
    }

    /// @dev Returns the number of live (not yet swept) positions
    function positionsLength() external view returns (uint256) {
        return positions.length;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Clones a fresh position and whitelists it on the EUR vault's active gates.
    /// @dev The gates are read live from the EUR vault (single source of truth: a gate rotation via
    ///      `setGates` is picked up automatically). `address(0)` (gateless) entries are skipped and
    ///      duplicates are whitelisted once (the same gate often serves several roles). Each active
    ///      gate must register this adapter as a trusted cloner of `positionImplementation`,
    ///      otherwise position creation reverts.
    function _createPosition() internal returns (address position) {
        bytes32 salt = bytes32(positionNonce++);
        position = Clones.cloneDeterministic(positionImplementation, salt);

        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        address[4] memory gates = [v.receiveSharesGate(), v.sendSharesGate(), v.receiveAssetsGate(), v.sendAssetsGate()];
        for (uint256 i; i < 4;) {
            address gate = gates[i];
            if (gate != address(0) && !_seenBefore(gates, gate, i)) {
                ICloneWhitelistGate(gate).setIsCloneWhitelisted(salt, true);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev True if `gate` already appears in `gates[0..i)`.
    function _seenBefore(address[4] memory gates, address gate, uint256 i) internal pure returns (bool) {
        for (uint256 j; j < i;) {
            if (gates[j] == gate) return true;
            unchecked {
                ++j;
            }
        }
        return false;
    }

    /// @dev Mirrors the EUR vault's request routing: `currentBatchId` when idle, `nextBatchId` during a DNT.
    function _activeBatchId() internal view returns (uint256) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        return v.vaultState() == IByzantinePrimeEURVault.VaultState.NormalIdle ? v.currentBatchId() : v.nextBatchId();
    }

    /// @dev Routes `assets` into the active batch's deposit position: opens one on first use, otherwise
    ///      aggregates into the existing one so the live-position count stays bounded by open batches.
    function _routeDeposit(uint256 assets) internal returns (address position, uint256 batchId, uint256 netAssets) {
        batchId = _activeBatchId();
        position = depositPositionOf[batchId];
        if (position == address(0)) {
            position = _createPosition();
            depositPositionOf[batchId] = position;
            positions.push(position);
            SafeERC20Lib.safeTransfer(asset, position, assets);
            (, netAssets) = IEurVaultPosition(position).initDeposit(assets);
        } else {
            SafeERC20Lib.safeTransfer(asset, position, assets);
            netAssets = IEurVaultPosition(position).addDeposit(assets);
        }
    }

    /// @dev Withdraw-side mirror of `_routeDeposit`.
    function _routeWithdraw(uint256 shares) internal returns (address position, uint256 batchId) {
        batchId = _activeBatchId();
        position = withdrawPositionOf[batchId];
        if (position == address(0)) {
            position = _createPosition();
            withdrawPositionOf[batchId] = position;
            positions.push(position);
            SafeERC20Lib.safeTransfer(eurVault, position, shares);
            IEurVaultPosition(position).initWithdraw(shares);
        } else {
            SafeERC20Lib.safeTransfer(eurVault, position, shares);
            IEurVaultPosition(position).addWithdraw(shares);
        }
    }

    /// @dev Sweeps up to `maxPositions` settled positions (claims + transfers their proceeds to the
    ///      adapter) and removes them from `positions` (swap-and-pop).
    function _sweepSettled(uint256 maxPositions) internal {
        uint256 i;
        uint256 swept;
        while (i < positions.length && swept < maxPositions) {
            IEurVaultPosition position = IEurVaultPosition(positions[i]);
            if (position.settled()) {
                // Drop this position's batch->position mapping entry before sweeping it.
                uint256 bid = position.batchId();
                if (depositPositionOf[bid] == address(position)) delete depositPositionOf[bid];
                else if (withdrawPositionOf[bid] == address(position)) delete withdrawPositionOf[bid];

                (uint256 shares, uint256 eurc) = position.sweep();
                emit SweepPosition(address(position), shares, eurc);
                // Swap the last element into the current position and pop the last element
                uint256 lastIndex = positions.length - 1;
                if (i != lastIndex) positions[i] = positions[lastIndex];
                positions.pop();
                unchecked {
                    ++swept;
                }
                // Re-check the swapped-in element at index i; do not increment.
            } else {
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @dev `realAssets` is the sum of:
    /// (A) idle EURC on the adapter,
    /// (B) convertToAssets(bpEUR balance on the adapter),
    /// (C) the value of every live position (see `EurVaultPosition.value()`): real holdings once its
    ///     batch closed, the stored pending amount before that.
    /// @dev The adapter itself is never the owner or receiver of an EUR-vault request (positions contracts are)
    /// @dev Known transient imprecision (upward only, self-clearing at batch close): see
    ///      `EurVaultPosition.value()`. The parent vault's maxRate cap smooths the upward direction.
    function _realAssets() internal view returns (uint256 total) {
        total = IERC20(asset).balanceOf(address(this));

        uint256 shares = IERC20(eurVault).balanceOf(address(this));
        if (shares != 0) total += IByzantinePrimeEURVault(eurVault).convertToAssets(shares);

        uint256 length = positions.length;
        for (uint256 i; i < length;) {
            total += IEurVaultPosition(positions[i]).value();
            unchecked {
                ++i;
            }
        }
    }
}
