// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IByzantinePrimeEURVault} from "./interfaces/IByzantinePrimeEURVault.sol";
import {IByzantineEurVaultAdapter} from "./interfaces/IByzantineEurVaultAdapter.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";

contract ByzantineEurVaultAdapter is IByzantineEurVaultAdapter {
    /* IMMUTABLES */

    address public immutable factory;
    address public immutable parentVault;
    address public immutable eurVault;
    address public immutable asset;
    bytes32 public immutable adapterId;

    /* STORAGE */

    address public skimRecipient;

    /// Mapping of batchId to pending deposit EURC
    /// @dev EURC that is deposited into the EUR vault but the deposit is not yet settled
    ///      bpEUR shares are minted at the next DNT settlement
    mapping(uint256 batchId => uint256) pendingDepositEurc;

    /// Mapping of batchId to pending withdraw shares
    /// @dev bpEUR that are burned from the EUR vault but the withdraw is not yet settled
    ///      EURC is transferred to the adapter at the next DNT settlement
    mapping(uint256 batchId => uint256) pendingWithdrawShares;

    /// @dev True if `batchId` is currently in `openBatchIds`
    mapping(uint256 batchId => bool) public isOpen;

    /// @dev Batches the adapter has pending state for
    uint256[] public openBatchIds;

    /* CONSTRUCTOR */

    constructor(address _parentVault, address _eurVault) {
        factory = msg.sender;
        parentVault = _parentVault;
        eurVault = _eurVault;
        asset = IByzantinePrimeEURVault(_eurVault).asset();
        require(asset == IVaultV2(_parentVault).asset(), AssetMismatch());
        adapterId = keccak256(abi.encode("this", address(this)));
        SafeERC20Lib.safeApprove(asset, _eurVault, type(uint256).max);
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS */

    /// @dev Allocates `assets` to the adapter and calls requestDeposit on the EUR vault.
    /// @dev Assets are transferred immediately to the adapter while bpEUR shares are minted at the next DNT settlement.
    function allocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256) {
        require(msg.sender == parentVault, Unauthorized());
        require(data.length == 0, InvalidData());

        uint256 oldAllocation = allocation();
        uint256 batchId = _activeBatchId();

        // The EUR vault deducts depositFeeBps on requestDeposit. Record the net
        // amount so realAssets reflects what we actually expect back as shares
        uint256 netAssets = _netAssetsAfterDepositFee(assets);

        IByzantinePrimeEURVault(eurVault).requestDeposit(assets, address(this));

        // If the batch is not open, add it to the open batch ids and set the open flag
        if (!isOpen[batchId]) {
            openBatchIds.push(batchId);
            isOpen[batchId] = true;
        }

        // Record the net assets for the batch
        pendingDepositEurc[batchId] += netAssets;

        emit Allocate(batchId, assets, netAssets);

        // newAllocation reflects the position right after requestDeposit
        uint256 newAllocation = _realAssets();

        // forge-lint: disable-next-item(unsafe-typecast) safe because ByzantinePrimeEURVault's position
        // is bounded by EURC's total supply, and allocation is less than the max total assets of the vault.
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @dev Allows deallocation only if the adapter has enough idle EURC.
    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory, int256)
    {
        require(msg.sender == parentVault, Unauthorized());
        require(data.length == 0, InvalidData());

        uint256 oldAllocation = allocation();

        // Only allowed to deallocate if the adapter has enough idle EURC
        require(IERC20(asset).balanceOf(address(this)) >= assets, InsufficientIdle());

        emit Deallocate(assets);

        // Reflects the post-transfer state: current realAssets minus the assets VaultV2 is about to pull
        uint256 newAllocation = _realAssets() - assets;

        // forge-lint: disable-next-item(unsafe-typecast) safe because ByzantinePrimeEURVault's position
        // is bounded by EURC's total supply, and allocation is less than the max total assets of the vault.
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @dev Callable by parent vault curator only.
    /// @dev bpEUR shares are burned immediately while withdrawn assets are transferred to the adapter at the next DNT
    /// settlement.
    function requestWithdraw(uint256 shares) external {
        require(msg.sender == IVaultV2(parentVault).curator(), Unauthorized());

        uint256 batchId = _activeBatchId();
        // Burns `shares` bpEUR from the adapter immediately and queues the request.
        IByzantinePrimeEURVault(eurVault).requestWithdraw(shares, address(this), address(this));

        if (!isOpen[batchId]) {
            openBatchIds.push(batchId);
            isOpen[batchId] = true;
        }
        pendingWithdrawShares[batchId] += shares;

        emit RequestWithdraw(batchId, shares);
    }

    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == IVaultV2(parentVault).curator(), Unauthorized());
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @dev Skims the adapter's balance of `token` and sends it to `skimRecipient`.
    /// @dev This is useful to handle rewards that the adapter has earned.
    function skim(address token) external {
        require(msg.sender == skimRecipient, Unauthorized());
        require(token != asset, CannotSkimEurc());
        require(token != eurVault, CannotSkimBpEur());
        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, skimRecipient, balance);
        emit Skim(token, balance);
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

    /// @dev Returns the number of open batch ids
    function openBatchIdsLength() external view returns (uint256) {
        return openBatchIds.length;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Returns the active batch id in the Byzantine EUR vault
    function _activeBatchId() internal view returns (uint256) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        return v.vaultState() == IByzantinePrimeEURVault.VaultState.NormalIdle ? v.currentBatchId() : v.nextBatchId();
    }

    /// @dev ceil(assets * bps / 10_000), matching ByzantinePrimeEURVault.requestDeposit
    /// @dev Used to increment `pendingDepositEurc` in `allocate`
    function _netAssetsAfterDepositFee(uint256 assets) internal view returns (uint256) {
        uint256 bps = IByzantinePrimeEURVault(eurVault).depositFeeBps();
        if (bps == 0) return assets;
        // Calculate the deposit fee
        uint256 fee = Math.mulDiv(assets, bps, 10_000, Math.Rounding.Ceil);
        return assets - fee;
    }

    /// @dev `realAssets` is the sum of:
    /// (A) idle EURC on the adapter,
    /// (B) gate-blocked EURC on the EUR vault,
    /// (C) convertToAssets(bpEURBalance + claimableShares[adapter]) - value of the bpEUR position and gate-blocked
    ///     bpEUR shares,
    /// (D) pending deposit EURC, summed over open EUR-vault batches not yet settled,
    /// (E) convertToAssets(pendingWithdrawShares) - summed over the same set.
    /// @dev The EUR vault's batch state machine guarantees at most two in-flight batches
    ///      (`currentBatchId` and `nextBatchId`), so the per-batch loop iterates at most twice.
    function _realAssets() internal view returns (uint256 total) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);

        // (A) idle EURC + (B) gate-blocked EURC on the EUR vault
        total = IERC20(asset).balanceOf(address(this)) + v.claimableEurc(address(this));

        // (C) bpEUR position value (adapter-held + gate-blocked, both convert at same rate)
        uint256 totalShares = IERC20(eurVault).balanceOf(address(this)) + v.claimableShares(address(this));
        if (totalShares != 0) total += v.convertToAssets(totalShares);

        uint256 settledUpTo = v.currentBatchId();
        uint256 length = openBatchIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 batchId = openBatchIds[i];
            // Already-settled but not yet cleaned up.
            if (batchId < settledUpTo) continue;
            total += pendingDepositEurc[batchId];
            uint256 burnedShares = pendingWithdrawShares[batchId];
            if (burnedShares != 0) total += v.convertToAssets(burnedShares);
        }
    }
}
