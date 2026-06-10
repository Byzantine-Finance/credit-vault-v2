// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IByzantinePrimeEURVault} from "../interfaces/IByzantinePrimeEURVault.sol";
import {IEurVaultPosition} from "./interfaces/IEurVaultPosition.sol";

/// @title  EurVaultPosition
/// @notice EIP-1167 minimal-proxy position used by `ByzantineEurVaultAdapter`.
/// @dev    One clone == exactly one ByzantineEURVault request (deposit OR withdraw). The clone is the
///         owner and receiver of its single ticket, so every bpEUR share or EURC the EUR vault
///         settles for that ticket lands at this address and nowhere else.
/// @dev    Lifecycle: cloned and funded by the adapter, initialized (one ByzantineEURVault request),
///         valued by `value()` while live, then swept back to the adapter once its batch closes
///         and dropped from the adapter's tracking.
contract EurVaultPosition is IEurVaultPosition {
    using MathLib for uint256;

    /* IMMUTABLES */
    // Embedded in the implementation's bytecode, shared by every clone through delegatecall.

    address public immutable adapter;
    address public immutable eurVault;
    address public immutable asset;

    /* STORAGE */
    // Per clone storage

    /// @dev EUR-vault batch id this ticket was queued into.
    uint256 public batchId;
    /// @dev Deposit position: EURC queued, net of the deposit fee.
    uint256 public pendingEurc;
    /// @dev Withdraw position: bpEUR burned at request time.
    uint256 public pendingShares;

    /* CONSTRUCTOR */

    constructor(address _eurVault, address _asset) {
        adapter = msg.sender;
        eurVault = _eurVault;
        asset = _asset;
    }

    /* INITIALIZERS (adapter only, once) */

    /// @dev Opens a deposit ticket. The adapter must have transferred `assets` EURC to this clone first.
    /// @return batchId_ The EUR-vault batch id the ticket was queued into.
    /// @return netAssets `assets` net of the EUR vault's deposit fee.
    function initDeposit(uint256 assets) external returns (uint256 batchId_, uint256 netAssets) {
        require(msg.sender == adapter, NotAdapter());
        require(batchId == 0, AlreadyInitialized());

        SafeERC20Lib.safeApprove(asset, eurVault, assets);
        IByzantinePrimeEURVault(eurVault).requestDeposit(assets, address(this));

        batchId_ = _activeBatchId();
        netAssets = _netAssetsAfterDepositFee(assets);
        batchId = batchId_;
        pendingEurc = netAssets;
    }

    /// @dev Opens a withdraw ticket. The adapter must have transferred `shares` bpEUR to this clone first.
    ///      The EUR vault burns the shares immediately; the EURC payout settles at the next DNT.
    /// @return batchId_ The EUR-vault batch id the ticket was queued into.
    function initWithdraw(uint256 shares) external returns (uint256 batchId_) {
        require(msg.sender == adapter, NotAdapter());
        require(batchId == 0, AlreadyInitialized());

        IByzantinePrimeEURVault(eurVault).requestWithdraw(shares, address(this), address(this));

        batchId_ = _activeBatchId();
        batchId = batchId_;
        pendingShares = shares;
    }

    /* VIEWS */

    /// @dev True once the EUR vault has closed this position's batch
    ///      Close-based on purpose: it cannot be forged by donating tokens to this clone.
    function settled() public view returns (bool) {
        return IByzantinePrimeEURVault(eurVault).currentBatchId() > batchId;
    }

    /// @dev The position's value in EURC terms. Two valuation modes, switched by `settled()`:
    ///
    ///      - Settled (batch closed): what the clone actually holds — EURC and bpEUR balances plus
    ///        any gate-blocked claimables, with bpEUR priced at the current PPS.
    ///
    ///      - Pending (batch not closed, including mid-DNT): the stored request amount —
    ///        `pendingEurc` for a deposit, `previewRedeemNetAssets(pendingShares)` for a withdraw
    ///        (net of the protocol withdraw fee, read live so governance fee changes are tracked).
    ///
    ///      Donation safety: in pending mode no balance is read, so sending tokens to the clone
    ///      cannot alter its valuation; in settled mode a donation can only push the value UP,
    ///      a direction the parent vault's maxRate cap absorbs.
    ///
    /// @dev Accepted transient over-statement: when this ticket has been processed during the
    ///      chunked finalize but the batch is not closed yet, the position is still valued at its
    ///      pending amount, which does not include the hedge-partner swap fee realized at DNT
    ///      execution ( because that fee depends on the batch's netting ratio, unknown at request time).
    ///
    ///      For a deposit the over-statement is bounded by
    ///        (hedgeSwapFeeBps / 10_000) × (dntDepositEurcNet / dntDepositsEurc) × pendingEurc
    ///
    ///      For a withdraw same logic.
    ///
    ///      The over-statement disappears at batch close.
    ///      The error direction is deliberate: the parent vault's maxRate cap smooths upward moves
    ///      of `realAssets()`, whereas an under-statement would pass through immediately as a
    ///      phantom loss.
    ///
    /// @dev Two more known imprecisions. Like the fees above, both can only OVER-state (never
    ///      under-state) and both correct themselves when the batch closes:
    ///      - If the EUR vault does not have enough EURC to pay all of a batch's withdrawals, it
    ///        pays everyone pro-rata (the "withdrawal budget" haircut). A pending withdraw position
    ///        is valued at 100% of its shares because this shortfall cannot be known before
    ///        settlement. The loss only shows up once the batch closes and the position is valued
    ///        at the EURC it actually received.
    ///      - During a DNT, `convertToAssets` returns the price frozen for the batch being settled.
    ///        A withdraw position waiting in the NEXT batch is valued with that frozen price too,
    ///        while its real payout will use the price of its own, later DNT. The error is at most
    ///        the price move between two consecutive batches.
    function value() external view returns (uint256) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);

        if (settled()) {
            uint256 shares = IERC20(eurVault).balanceOf(address(this)) + v.claimableShares(address(this));
            uint256 eurc = IERC20(asset).balanceOf(address(this)) + v.claimableEurc(address(this));
            return shares != 0 ? eurc + v.convertToAssets(shares) : eurc;
        }

        uint256 pendingShares_ = pendingShares;
        return pendingShares_ != 0 ? v.previewRedeemNetAssets(pendingShares_) : pendingEurc;
    }

    /* SWEEP (adapter only, after settlement) */

    /// @dev Claims any gate-blocked proceeds straight to the adapter, then transfers the clone's
    ///      bpEUR and EURC balances back to the adapter. After a sweep the position contract holds nothing
    ///      and the adapter drops it from its tracking.
    /// @return shares Total bpEUR returned to the adapter (claimed + held).
    /// @return eurc Total EURC returned to the adapter (claimed + held).
    function sweep() external returns (uint256 shares, uint256 eurc) {
        require(msg.sender == adapter, NotAdapter());
        require(settled(), NotSettled());

        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);

        // Claims are keyed to this clone (the ticket's owner) and sent directly to the adapter.
        uint256 claimableShares_ = v.claimableShares(address(this));
        if (claimableShares_ != 0) v.claimDepositShares(adapter);
        uint256 claimableEurc_ = v.claimableEurc(address(this));
        if (claimableEurc_ != 0) v.claimWithdraw(adapter);

        shares = IERC20(eurVault).balanceOf(address(this));
        if (shares != 0) SafeERC20Lib.safeTransfer(eurVault, adapter, shares);
        shares += claimableShares_;

        eurc = IERC20(asset).balanceOf(address(this));
        if (eurc != 0) SafeERC20Lib.safeTransfer(asset, adapter, eurc);
        eurc += claimableEurc_;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Mirrors the EUR vault's `_activeBatchIdForRequests`: requests queue on `currentBatchId`
    ///      when idle and on `nextBatchId` while a DNT is in progress.
    function _activeBatchId() internal view returns (uint256) {
        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        return v.vaultState() == IByzantinePrimeEURVault.VaultState.NormalIdle ? v.currentBatchId() : v.nextBatchId();
    }

    /// @dev ceil(assets * bps / 10_000), matching ByzantinePrimeEURVault.requestDeposit.
    function _netAssetsAfterDepositFee(uint256 assets) internal view returns (uint256) {
        uint256 bps = IByzantinePrimeEURVault(eurVault).depositFeeBps();
        if (bps == 0) return assets;
        uint256 fee = assets.mulDivUp(bps, 10_000);
        return assets - fee;
    }
}
