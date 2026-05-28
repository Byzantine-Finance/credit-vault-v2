// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IByzantinePrimeEURVault} from "../interfaces/IByzantinePrimeEURVault.sol";
import {IByzantineEurVaultAdapter} from "./interfaces/IByzantineEurVaultAdapter.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";

contract ByzantineEurVaultAdapter is IByzantineEurVaultAdapter {
    using MathLib for uint256;

    /* IMMUTABLES */

    address public immutable factory;
    address public immutable parentVault;
    address public immutable eurVault;
    address public immutable asset;
    bytes32 public immutable adapterId;

    /* STORAGE */

    address public skimRecipient;
    address public adapterCurator;

    /// @dev Per-batch accounting state. Struct defined in `IByzantineEurVaultAdapter`.
    mapping(uint256 batchId => BatchAccounting) public batchAccounting;

    /// @dev Batches the adapter has pending state for
    uint256[] public openBatchIds;

    /* CONSTRUCTOR */

    constructor(address _parentVault, address _eurVault) {
        factory = msg.sender;
        parentVault = _parentVault;
        eurVault = _eurVault;
        asset = IVaultV2(_parentVault).asset();
        require(asset == IByzantinePrimeEURVault(_eurVault).asset(), AssetMismatch());
        adapterId = keccak256(abi.encode("this", address(this)));
        SafeERC20Lib.safeApprove(asset, _eurVault, type(uint256).max);
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS */

    /// @dev Allocates `assets` to the adapter and calls requestDeposit on the EUR vault.
    /// @dev Assets are transferred immediately to the adapter while bpEUR shares are minted at the next DNT settlement.
    function allocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256) {
        require(msg.sender == parentVault, NotAuthorized());
        require(data.length == 0, InvalidData());

        // Transfer the assets to the EUR vault
        if (assets > 0) IByzantinePrimeEURVault(eurVault).requestDeposit(assets, address(this));

        // Clean up settled batches in openBatchIds
        _clearSettledBatches();

        // Get the active batch id
        uint256 batchId = _activeBatchId();

        // The EUR vault deducts depositFeeBps on requestDeposit. Record the net
        // amount so realAssets reflects what we actually expect back as shares
        uint256 netAssets = _netAssetsAfterDepositFee(assets);
        BatchAccounting storage acc = batchAccounting[batchId];
        // forge-lint: disable-next-line(unsafe-typecast) `netAssets` is bounded by EURC supply.
        acc.pendingDepositEurc += uint128(netAssets);

        // If the batch is not open, snapshot balances and add it to the open batch ids.
        if (!acc.isOpen) {
            _snapshotBalancesForBatch(batchId);
            openBatchIds.push(batchId);
            acc.isOpen = true;
        }

        // newAllocation reflects the position right after requestDeposit
        uint256 oldAllocation = allocation();
        uint256 newAllocation = _realAssets();

        emit Allocate(batchId, assets, netAssets);

        // forge-lint: disable-next-item(unsafe-typecast) safe because ByzantinePrimeEURVault's position
        // is bounded by EURC's total supply, and allocation is less than the max total assets of the vault.
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @dev Allows deallocation only if the adapter has enough idle EURC.
    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory, int256)
    {
        require(msg.sender == parentVault, NotAuthorized());
        require(data.length == 0, InvalidData());

        // Clean up settled batches in openBatchIds
        _clearSettledBatches();

        // Pulls any claimable EURC so the adapter can include it in the deallocation
        _pullClaimableEurc();

        // Only allowed to deallocate if the adapter has enough idle EURC
        require(IERC20(asset).balanceOf(address(this)) >= assets, InsufficientIdle());

        // Reflects the post-transfer state: current realAssets minus the assets VaultV2 is about to pull
        uint256 oldAllocation = allocation();
        uint256 newAllocation = _realAssets() - assets;

        // `assets` will be transfered out from the adapter
        // Adjust snapshots now so `_realAssets` call observe a consistent state.
        _adjustEurcSnapshotOnTransferOut(assets);

        emit Deallocate(assets);

        // forge-lint: disable-next-item(unsafe-typecast) safe because ByzantinePrimeEURVault's position
        // is bounded by EURC's total supply, and allocation is less than the max total assets of the vault.
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @dev Callable by adapter curator only.
    /// @dev Deposits `assets` of idle EURC held by the adapter into the EUR vault to earn yield.
    ///      The EURC leaves the adapter immediately while bpEUR shares are minted at the next DNT settlement.
    function requestDeposit(uint256 assets) external {
        require(msg.sender == adapterCurator, NotAuthorized());

        // Clean up settled batches in openBatchIds
        _clearSettledBatches();

        // Pulls any claimable EURC so the adapter can include it in the deposit
        _pullClaimableEurc();

        // Only allowed to deposit if the adapter has enough idle EURC
        require(IERC20(asset).balanceOf(address(this)) >= assets, InsufficientIdle());

        // Transfer the assets to the EUR vault. Reverts on zero assets via the vault's own check.
        IByzantinePrimeEURVault(eurVault).requestDeposit(assets, address(this));

        // `assets` left the adapter to the EUR vault.
        // Adjust EURC snapshots of existing open batches so future settlement-delta calculations remain consistent.
        _adjustEurcSnapshotOnTransferOut(assets);

        // Get the active batch id
        uint256 batchId = _activeBatchId();

        // The EUR vault deducts depositFeeBps on requestDeposit. Record the net
        // amount so realAssets reflects what we actually expect back as shares
        uint256 netAssets = _netAssetsAfterDepositFee(assets);
        BatchAccounting storage acc = batchAccounting[batchId];
        // forge-lint: disable-next-line(unsafe-typecast) `netAssets` is bounded by EURC supply.
        acc.pendingDepositEurc += uint128(netAssets);

        // If the batch is not open, snapshot balances and add it to the open batch ids.
        if (!acc.isOpen) {
            _snapshotBalancesForBatch(batchId);
            openBatchIds.push(batchId);
            acc.isOpen = true;
        }

        emit RequestDeposit(batchId, assets, netAssets);
    }

    /// @dev Callable by adapter curator only.
    /// @dev bpEUR shares are burned immediately while withdrawn assets are transferred to the adapter at the next DNT
    ///      settlement.
    function requestWithdraw(uint256 shares) external {
        require(msg.sender == adapterCurator, NotAuthorized());

        // Clean up settled batches in openBatchIds
        _clearSettledBatches();

        // Pulls any claimable bpEUR shares so the adapter can include them in the request
        _pullClaimableShares();

        // Burns `shares` bpEUR from the adapter immediately and queues the request.
        IByzantinePrimeEURVault(eurVault).requestWithdraw(shares, address(this), address(this));

        // `shares` will be burned from the adapter
        // Adjust snapshots now so `_realAssets` (called below) and any subsequent call observe a consistent state.
        _adjustSharesSnapshotsOnBurn(shares);

        // Get the active batch id
        uint256 batchId = _activeBatchId();

        // If the batch is not open, snapshot balances and add it to the open batch ids.
        BatchAccounting storage acc = batchAccounting[batchId];
        if (!acc.isOpen) {
            _snapshotBalancesForBatch(batchId);
            openBatchIds.push(batchId);
            acc.isOpen = true;
        }
        acc.pendingWithdrawShares += shares;

        emit RequestWithdraw(batchId, shares);
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

    /// @dev Pulls claimable bpEUR shares from the EUR vault and clear settled batches as a side-effect.
    function pullClaimableShares() external {
        _clearSettledBatches();
        _pullClaimableShares();
    }

    /// @dev Pulls claimable EURC from the EUR vault and clear settled batches as a side-effect.
    function pullClaimableEurc() external {
        _clearSettledBatches();
        _pullClaimableEurc();
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
        uint256 fee = assets.mulDivUp(bps, 10_000);
        return assets - fee;
    }

    /// @dev Reads the adapter's current bpEUR and EURC balances and adds the claimable tokens in the EUR vault.
    function _currentBalances() internal view returns (uint256 shares, uint256 eurc) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        shares = IERC20(eurVault).balanceOf(address(this)) + v.claimableShares(address(this));
        eurc = IERC20(asset).balanceOf(address(this)) + v.claimableEurc(address(this));
    }

    /// @dev Snapshots `(shares, eurc)` at batch open for `batchId`. Called when the batch is first added
    ///      to `openBatchIds`, so `_realAssets` can compute the passive delta attributable to this batch's
    ///      settlement as `int256(current) - acc.sharesSnapshotAtBatch` (resp. `acc.eurcSnapshotAtBatch`).
    // forge-lint: disable-next-item(unsafe-typecast) bpEUR and EURC supplies are bounded far below 2^255.
    function _snapshotBalancesForBatch(uint256 batchId) internal {
        (uint256 shares, uint256 eurc) = _currentBalances();
        BatchAccounting storage acc = batchAccounting[batchId];
        acc.sharesSnapshotAtBatch = int256(shares);
        acc.eurcSnapshotAtBatch = int128(int256(eurc));
    }

    /// @dev Decrements every open batch's `sharesSnapshotAtBatch` by `shares` after a burn (requestWithdraw).
    ///      The signed encoding allows the snapshot to drop below zero when the burn exceeds it, allowing accounting of
    ///      any deficit.
    // forge-lint: disable-next-item(unsafe-typecast) `shares` is bounded by bpEUR supply.
    function _adjustSharesSnapshotsOnBurn(uint256 shares) internal {
        int256 sharesInt = int256(shares);
        uint256 length = openBatchIds.length;
        for (uint256 i; i < length;) {
            batchAccounting[openBatchIds[i]].sharesSnapshotAtBatch -= sharesInt;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Decrements every open batch's `eurcSnapshotAtBatch` by `amount` before an outgoing EURC transfer.
    ///      Same signed-encoding rationale as `_adjustSharesSnapshotsOnBurn`.
    // forge-lint: disable-next-item(unsafe-typecast) `amount` is bounded by EURC supply.
    function _adjustEurcSnapshotOnTransferOut(uint256 amount) internal {
        int128 amountInt = int128(int256(amount));
        uint256 length = openBatchIds.length;
        for (uint256 i; i < length;) {
            batchAccounting[openBatchIds[i]].eurcSnapshotAtBatch -= amountInt;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev `realAssets` is the sum of:
    /// (A) idle EURC on the adapter + claimable EURC on the EUR vault
    /// (B) convertToAssets(sharesBalance + claimable shares on the EUR vault)
    /// (C) pending deposit EURC - summed over open EUR-vault batches not yet settled,
    /// (D) convertToAssets(pendingWithdrawShares) - summed over the same set.
    /// @dev For the batch currently being settled by the EUR vault (`currentBatchId` during `DntInProgress`),
    ///      (C) and (D) are reduced by the portion that has already been minted/transferred to the adapter
    ///      This is detected via `current - snapshot` deltas and avoids the
    ///      double-counting that would otherwise occur between ticket processing and batch close.
    /// @dev Known imprecision: during the active-settlement window of a batch, `realAssets()` may
    ///      transiently over-state by at most
    ///        (hedgeSwapFeeBps / 10_000) × (dntDepositEurcNet / dntDepositsEurc) ×
    ///        batchAccounting[currentBatchId].pendingDepositEurc
    ///      (and symmetrically on the withdraw side). This residue corresponds to the hedge-partner
    ///      swap fee that is only realized off-chain and cannot be pre-deducted because the per-batch
    ///      netting ratio is unknown until DNT execute.
    /// @dev All `int256(uint256)` casts are bounded by token supplies (far below 2^255); the symmetric
    ///      `uint256(int256)` casts are guarded by an explicit positivity check, so the function-level
    ///      `disable-next-item(unsafe-typecast)` below is safe.
    // forge-lint: disable-next-item(unsafe-typecast)
    function _realAssets() internal view returns (uint256 total) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);

        (uint256 currentShares, uint256 currentEurc) = _currentBalances();

        // (A) idle EURC + claimable EURC
        total = currentEurc;

        // (B) bpEUR position value (adapter-held + claimable, both convert at the same rate)
        if (currentShares != 0) total += v.convertToAssets(currentShares);

        uint256 closedBelow = v.currentBatchId();
        bool isDnt = v.vaultState() == IByzantinePrimeEURVault.VaultState.DntInProgress;
        uint256 length = openBatchIds.length;

        for (uint256 i; i < length;) {
            uint256 batchId = openBatchIds[i];
            // Batch not yet or currently being settled.
            if (batchId >= closedBelow) {
                BatchAccounting storage acc = batchAccounting[batchId];
                uint256 pendingDepEurc = acc.pendingDepositEurc; // (C)
                uint256 pendingWithShares = acc.pendingWithdrawShares;
                uint256 pendingWithEurc = pendingWithShares != 0 ? v.convertToAssets(pendingWithShares) : 0; // (D)

                // Batch currently being settled by the EUR vault
                // Track edge case where tickets are processed but batch is not closed.
                if (isDnt && batchId == closedBelow) {
                    // Check if any deposit tickets have silently processed
                    int256 currentSharesInt = int256(currentShares);
                    int256 sharesSnapshot = acc.sharesSnapshotAtBatch;
                    uint256 sharesDelta =
                        currentSharesInt > sharesSnapshot ? uint256(currentSharesInt - sharesSnapshot) : 0;
                    uint256 eurcDelta = sharesDelta != 0 ? v.convertToAssets(sharesDelta) : 0;
                    pendingDepEurc = pendingDepEurc > eurcDelta ? pendingDepEurc - eurcDelta : 0;

                    // Check if any withdraw tickets have silently processed
                    int256 currentEurcInt = int256(currentEurc);
                    int256 eurcSnapshot = acc.eurcSnapshotAtBatch;
                    eurcDelta = currentEurcInt > eurcSnapshot ? uint256(currentEurcInt - eurcSnapshot) : 0;
                    pendingWithEurc = pendingWithEurc > eurcDelta ? pendingWithEurc - eurcDelta : 0;
                }

                total += pendingDepEurc + pendingWithEurc;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Pulls claimable bpEUR shares from the EUR vault
    function _pullClaimableShares() internal {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        uint256 shares = v.claimableShares(address(this));
        if (shares == 0) return;
        v.claimDepositShares(address(this));
        emit PullClaimableShares(shares);
    }

    /// @dev Pulls claimable EURC from the EUR vault
    function _pullClaimableEurc() internal {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        uint256 amount = v.claimableEurc(address(this));
        if (amount == 0) return;
        v.claimWithdraw(address(this));
        emit PullClaimableEurc(amount);
    }

    /// @dev Removes entries from `openBatchIds` whose batchId have been settled, zeroing its storage.
    ///      After clearing, re-anchors the snapshots of the remaining open batches to the current state.
    /// @dev Called automatically by allocate/deallocate/requestWithdraw/pullClaimable*.
    /// @dev The re-anchor casts are bounded by token supplies (far below 2^255).
    /// forge-lint: disable-next-item(unsafe-typecast)
    function _clearSettledBatches() internal {
        // Get the current batch id from the EUR vault
        uint256 closedBelow = IByzantinePrimeEURVault(eurVault).currentBatchId();
        bool anyCleared;
        uint256 i;

        while (i < openBatchIds.length) {
            uint256 batchId = openBatchIds[i];
            if (batchId < closedBelow) {
                // Zero out all batch storage
                delete batchAccounting[batchId];
                // Swap the last element into the current position and pop the last element
                uint256 lastIndex = openBatchIds.length - 1;
                if (i != lastIndex) openBatchIds[i] = openBatchIds[lastIndex];
                openBatchIds.pop();
                anyCleared = true;
                emit ClearId(batchId);
                // Re-check the swapped-in element at index i; do not increment.
            } else {
                unchecked {
                    ++i;
                }
            }
        }

        // Re-anchor snapshots of remaining batches to the current state
        uint256 remaining = openBatchIds.length;
        if (anyCleared && remaining != 0) {
            (uint256 bp, uint256 eurc) = _currentBalances();
            int256 bpInt = int256(bp);
            int128 eurcInt = int128(int256(eurc));
            for (i = 0; i < remaining;) {
                BatchAccounting storage acc = batchAccounting[openBatchIds[i]];
                acc.sharesSnapshotAtBatch = bpInt;
                acc.eurcSnapshotAtBatch = eurcInt;
                unchecked {
                    ++i;
                }
            }
        }
    }
}
