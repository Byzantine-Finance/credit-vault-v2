// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import {VaultV2Factory, IVaultV2Factory} from "../../src/VaultV2Factory.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import "../../src/libraries/ConstantsLib.sol";

import {AaveStrategy} from "../../src/adapters/AaveStrategy.sol";
import {IMYTStrategy} from "../../src/adapters/interfaces/IMYTStrategy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {Test, console2} from "../../lib/forge-std/src/Test.sol";

interface IPoolAddressProvider {
    function getPool() external view returns (address);
}

interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/**
 * @notice Asset-agnostic integration suite for the {AaveStrategy} MYT adapter.
 */
abstract contract AaveStrategyAdapterIntegrationTest is Test {
    /* ========== AAVE V3 MAINNET INFRASTRUCTURE ========== */

    // PoolAddressesProvider.getPool() resolves to the Aave v3 Pool at the test block.
    address internal constant POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;

    // Incentives reward token that is used to encourage active participation from suppliers and borrowers
    // Use a placeholder token for testing purposes
    address internal constant REWARD_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    /* ========== FORK STATE ========== */

    string internal rpcUrl;
    uint256 internal forkId;

    /* ========== TEST ACCOUNTS ========== */

    address internal immutable owner = makeAddr("owner");
    address internal immutable curator = makeAddr("curator");
    address internal immutable allocator = makeAddr("allocator");
    address internal immutable sentinel = makeAddr("sentinel");
    address internal immutable strategyOwner = makeAddr("strategyOwner");
    address internal immutable user = makeAddr("user");

    /* ========== STRATEGY CONFIG ========== */

    uint256 internal constant SLIPPAGE_BPS = 50; // 0.5%

    /* ========== RESOLVED ASSET CONFIG (set in setUp) ========== */

    IERC20 internal asset;
    IERC20 internal aToken;

    /* ========== EXPECTED DATA ========== */

    bytes internal adapterIdData;
    bytes32 internal adapterId;

    /* ========== CONTRACTS ========== */

    IVaultV2Factory internal vaultFactory;
    IVaultV2 internal vault;
    AaveStrategy internal aaveStrategy;

    /* ========== CONFIG SUPPLIED BY CONCRETE SUITES ========== */

    /// @dev Mainnet fork block at which the chosen market is live and deterministic.
    function _forkBlock() internal pure virtual returns (uint256);

    /// @dev The vault's underlying ERC20 (e.g. USDC, EURC).
    function _underlying() internal pure virtual returns (IERC20);

    /// @dev The Aave v3 aToken for `_underlying()`.
    function _aToken() internal pure virtual returns (IERC20);

    function _vaultName() internal pure virtual returns (string memory);
    function _vaultSymbol() internal pure virtual returns (string memory);

    /// @dev A deposit size used for the "large" deposit/withdraw flow. Must fit within the
    ///      market's remaining supply cap. Override for small/capped markets (e.g. EURC).
    function _largeDepositAmount() internal pure virtual returns (uint256) {
        return 500_000e6;
    }

    /// @dev A deposit size used for the yield-accrual flow. Must fit within the market's
    ///      remaining supply cap while being large enough for interest to be observable.
    function _yieldDepositAmount() internal pure virtual returns (uint256) {
        return 100_000e6;
    }

    function setUp() public virtual {
        // Pin a specific block so interest/exchange-rate assertions are deterministic.
        rpcUrl = vm.envString("MAINNET_RPC_URL");
        forkId = vm.createFork(rpcUrl, _forkBlock());
        vm.selectFork(forkId);

        asset = _underlying();
        aToken = _aToken();

        // Sanity-check the market wiring of this fork.
        require(IPoolAddressProvider(POOL_ADDRESSES_PROVIDER).getPool() == AAVE_POOL, "Aave pool mismatch");
        require(IAToken(address(aToken)).UNDERLYING_ASSET_ADDRESS() == address(asset), "aToken/asset mismatch");

        vm.label(address(this), "testContract");
        vm.label(address(asset), "asset");
        vm.label(address(aToken), "aToken");
        vm.label(AAVE_POOL, "AavePool");
        vm.label(POOL_ADDRESSES_PROVIDER, "PoolAddressesProvider");
        vm.label(REWARDS_CONTROLLER, "RewardsController");

        // Deploy a fresh vault over the chosen underlying.
        vaultFactory = IVaultV2Factory(address(new VaultV2Factory()));
        vault = IVaultV2(vaultFactory.createVaultV2(owner, address(asset), bytes32(0)));
        vm.label(address(vault), "VaultV2");

        // Deploy the Aave strategy adapter.
        aaveStrategy = new AaveStrategy(
            address(vault),
            _strategyParams(),
            address(asset), // mytAsset
            address(aToken),
            POOL_ADDRESSES_PROVIDER,
            REWARDS_CONTROLLER,
            REWARD_TOKEN
        );
        require(aaveStrategy.MYT().asset() == address(asset), "vault asset mismatch");
        adapterIdData = abi.encode("this", address(aaveStrategy));
        adapterId = keccak256(adapterIdData);
        vm.label(address(aaveStrategy), "AaveStrategy");

        // Configure vault roles.
        vm.startPrank(owner);
        vault.setCurator(curator);
        vault.setIsSentinel(sentinel, true);
        vault.setName(_vaultName());
        vault.setSymbol(_vaultSymbol());
        vm.stopPrank();

        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);

        vault.submit(abi.encodeCall(IVaultV2.addAdapter, address(aaveStrategy)));
        vault.addAdapter(address(aaveStrategy));

        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (adapterIdData, type(uint128).max)));
        vault.increaseAbsoluteCap(adapterIdData, type(uint128).max);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (adapterIdData, WAD)));
        vault.increaseRelativeCap(adapterIdData, WAD);
        vm.stopPrank();

        // Enable interest accrual and route liquidity through the Aave strategy.
        vm.startPrank(allocator);
        vault.setMaxRate(MAX_MAX_RATE);
        vault.setLiquidityAdapterAndData(address(aaveStrategy), _directActionData());
        vm.stopPrank();

        // Fund the test contract and the primary user, and approve the vault.
        deal(address(asset), address(this), 1_000_000e6);
        asset.approve(address(vault), type(uint256).max);

        deal(address(asset), user, 1_000_000e6);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
        vm.label(user, "User");
    }

    /* ========== HELPERS ========== */

    /// @dev Default strategy parameters used when deploying the adapter.
    function _strategyParams() internal view returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: strategyOwner,
            name: "Aave Strategy",
            protocol: "Aave v3",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false,
            slippageBPS: SLIPPAGE_BPS
        });
    }

    /// @dev Encodes the adapter calldata for a plain (non-swap) allocate/deallocate.
    /// @dev This is what the vault passes as `liquidityData` and what manual allocations use.
    function _directActionData() internal pure returns (bytes memory) {
        return abi.encode(
            IMYTStrategy.VaultAdapterParams({
                action: IMYTStrategy.ActionType.direct,
                swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})
            })
        );
    }

    /* ========== SETUP / WIRING ========== */

    function testVaultDeployment() public view {
        assertEq(vault.asset(), address(asset));
        assertEq(vault.owner(), owner);
        assertEq(vault.curator(), curator);
        assertEq(vault.name(), _vaultName());
        assertEq(vault.symbol(), _vaultSymbol());

        assertTrue(vault.isAdapter(address(aaveStrategy)));
        assertEq(vault.liquidityAdapter(), address(aaveStrategy));

        assertEq(vault.absoluteCap(adapterId), type(uint128).max);
        assertEq(vault.relativeCap(adapterId), WAD);
    }

    function testAdapterProperties() public view {
        // Immutable wiring.
        assertEq(address(aaveStrategy.MYT()), address(vault));
        assertEq(address(aaveStrategy.mytAsset()), address(asset));
        assertEq(address(aaveStrategy.aToken()), address(aToken));
        assertEq(address(aaveStrategy.poolProvider()), POOL_ADDRESSES_PROVIDER);
        assertEq(address(aaveStrategy.rewardsController()), REWARDS_CONTROLLER);
        assertEq(address(aaveStrategy.rewardToken()), REWARD_TOKEN);
        assertEq(aaveStrategy.owner(), strategyOwner);

        // Id wiring matches the vault's accounting key.
        bytes32[] memory ids = aaveStrategy.ids();
        assertEq(ids.length, 1);
        assertEq(ids[0], adapterId);
        assertEq(aaveStrategy.adapterId(), adapterId);

        // No funds deployed yet.
        assertEq(aaveStrategy.allocation(), 0);
        assertEq(aaveStrategy.realAssets(), 0);
    }

    /* ========== DEPOSIT / WITHDRAW ========== */

    function testDepositAllocatesToAave() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);

        assertGt(shares, 0, "no shares minted");
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalSupply(), shares);

        // Funds were supplied to Aave: the strategy holds aTokens, the vault holds no idle asset.
        assertApproxEqAbs(aToken.balanceOf(address(aaveStrategy)), depositAmount, 1, "aToken balance");
        assertApproxEqAbs(asset.balanceOf(address(vault)), 0, 1, "vault should not hold idle asset");

        // Adapter accounting reflects the supplied principal.
        assertGt(aaveStrategy.allocation(), 0, "no allocation tracked");
        assertApproxEqAbs(aaveStrategy.realAssets(), depositAmount, 1, "real assets mismatch");
    }

    function testDepositAndMint() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);
        assertGt(shares, 0, "no shares minted");

        uint256 mintShares = shares / 2;
        vm.prank(user);
        uint256 assets = vault.mint(mintShares, user);

        assertGt(assets, 0, "no assets pulled for mint");
        assertEq(vault.balanceOf(user), shares + mintShares);
        // The minted assets were also routed to Aave.
        assertApproxEqAbs(aaveStrategy.realAssets(), depositAmount + assets, 2, "real assets after mint");
    }

    function testWithdrawAndRedeem() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);

        // Let a little interest accrue so the aToken balance covers Aave's 1-wei supply rounding,
        // allowing the position to be fully redeemed.
        skip(1 days);

        uint256 aTokenAfterDeposit = aToken.balanceOf(address(aaveStrategy));

        // Withdraw half: the vault has no idle asset, so it must deallocate from Aave.
        uint256 withdrawAmount = 5_000e6;
        uint256 userBalanceBefore = asset.balanceOf(user);

        vm.prank(user);
        uint256 sharesRedeemed = vault.withdraw(withdrawAmount, user, user);

        assertGt(sharesRedeemed, 0, "no shares redeemed");
        assertEq(asset.balanceOf(user) - userBalanceBefore, withdrawAmount, "user did not receive assets");
        assertEq(vault.balanceOf(user), shares - sharesRedeemed);
        assertLt(aToken.balanceOf(address(aaveStrategy)), aTokenAfterDeposit, "aToken did not decrease");

        // Redeem the remainder.
        uint256 remainingShares = vault.balanceOf(user);
        vm.prank(user);
        uint256 assetsReceived = vault.redeem(remainingShares, user, user);

        assertGt(assetsReceived, 0, "no assets received on redeem");
        assertEq(vault.balanceOf(user), 0);
    }

    function testLargeDepositAndWithdrawal() public {
        uint256 largeAmount = _largeDepositAmount();
        deal(address(asset), user, largeAmount);

        vm.prank(user);
        uint256 shares = vault.deposit(largeAmount, user);
        assertGt(shares, 0, "no shares for large deposit");
        assertApproxEqAbs(aaveStrategy.realAssets(), largeAmount, 2, "large deposit not fully allocated");

        uint256 withdrawAmount = largeAmount - 1_000e6;
        vm.prank(user);
        uint256 sharesRedeemed = vault.withdraw(withdrawAmount, user, user);

        assertGt(sharesRedeemed, 0, "no shares redeemed for large withdrawal");
        assertLt(vault.balanceOf(user), shares / 10, "should have withdrawn most shares");
    }

    /* ========== MANUAL ALLOCATE / DEALLOCATE ========== */

    function testManualAllocateAndDeallocate() public {
        uint256 depositAmount = 10_000e6;
        vm.prank(user);
        vault.deposit(depositAmount, user);

        uint256 initialAllocation = aaveStrategy.allocation();
        assertGt(initialAllocation, 0, "no initial allocation");

        // Allocate an extra amount funded directly into the vault.
        uint256 extra = 5_000e6;
        deal(address(asset), address(vault), extra);

        vm.prank(allocator);
        vault.allocate(address(aaveStrategy), _directActionData(), extra);
        assertApproxEqAbs(aaveStrategy.allocation(), initialAllocation + extra, 2, "allocation did not grow");

        // Deallocate it back: assets are withdrawn from Aave and returned to the vault.
        uint256 vaultIdleBefore = asset.balanceOf(address(vault));
        vm.prank(allocator);
        vault.deallocate(address(aaveStrategy), _directActionData(), extra);

        assertApproxEqAbs(aaveStrategy.allocation(), initialAllocation, 2, "deallocation failed");
        assertApproxEqAbs(asset.balanceOf(address(vault)) - vaultIdleBefore, extra, 1, "vault did not receive assets");
    }

    function testZeroAmountAllocateReverts() public {
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, 1, 0));
        vault.allocate(address(aaveStrategy), _directActionData(), 0);
    }

    function testOnlyVaultCanAllocateOrDeallocate() public {
        vm.expectRevert(bytes("PD"));
        aaveStrategy.allocate(_directActionData(), 1e6, bytes4(0), address(this));

        vm.expectRevert(bytes("PD"));
        aaveStrategy.deallocate(_directActionData(), 1e6, bytes4(0), address(this));
    }

    /* ========== ACCOUNTING / VALUATION ========== */

    function testRealAssetsTracksATokenPlusIdle() public {
        vm.prank(user);
        vault.deposit(10_000e6, user);

        uint256 expected = aToken.balanceOf(address(aaveStrategy)) + asset.balanceOf(address(aaveStrategy));
        assertEq(aaveStrategy.realAssets(), expected, "realAssets must equal aToken + idle");
    }

    function testPreviewAdjustedWithdrawAppliesSlippage() public {
        uint256 amount = 10_000e6;
        uint256 expected = amount - (amount * SLIPPAGE_BPS / 10_000);
        assertEq(aaveStrategy.previewAdjustedWithdraw(amount), expected, "default slippage mismatch");

        // Zero amount is rejected.
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, 1, 0));
        aaveStrategy.previewAdjustedWithdraw(0);
    }

    function testMaxFunctionsReturnZero() public view {
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxMint(user), 0);
        assertEq(vault.maxWithdraw(user), 0);
        assertEq(vault.maxRedeem(user), 0);
    }

    function testConversionFunctions() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);

        assertApproxEqAbs(vault.convertToShares(depositAmount), shares, 1, "share conversion mismatch");
        assertApproxEqAbs(vault.convertToAssets(shares), depositAmount, 1, "asset conversion mismatch");
    }

    function testPreviewFunctionsMatchActual() public {
        uint256 depositAmount = 10_000e6;

        uint256 previewShares = vault.previewDeposit(depositAmount);
        assertGt(previewShares, 0, "preview deposit failed");
        assertApproxEqAbs(vault.previewMint(previewShares), depositAmount, 1, "preview mint mismatch");

        vm.prank(user);
        uint256 actualShares = vault.deposit(depositAmount, user);
        assertApproxEqAbs(actualShares, previewShares, 1, "actual shares mismatch");
    }

    /* ========== YIELD ========== */

    /// @dev Shared body for the yield-accrual test. Concrete suites expose this through a
    ///      `test`-prefixed wrapper annotated to run in isolation mode: isolation makes each
    ///      call its own transaction, which is required because the vault snapshots
    ///      `firstTotalAssets` in transient storage per-transaction, so accrued interest only
    ///      becomes visible across separate transactions.
    /// @dev forge-config is declared in the Usde/EurcTest suites.
    function _checkYieldAccrualIsCapturedByVault(uint256 depositAmount) internal {
        vm.prank(user);
        vault.deposit(depositAmount, user);

        uint256 aTokenBefore = aToken.balanceOf(address(aaveStrategy));
        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 shareValueBefore = vault.previewRedeem(vault.balanceOf(user));

        assertApproxEqAbs(aTokenBefore, depositAmount, 1, "initial aToken should match deposit");
        assertApproxEqAbs(vaultAssetsBefore, depositAmount, 1, "initial vault assets should match deposit");

        // Let interest accrue on the live market.
        skip(30 days);

        // Aave accrues interest into the aToken balance.
        uint256 aTokenAfter = aToken.balanceOf(address(aaveStrategy));
        assertGt(aTokenAfter, aTokenBefore, "aToken should accrue interest over 30 days");

        // The vault surfaces that yield (idle is nearly 0, so totalAssets tracks the aToken balance).
        uint256 vaultAssetsAfter = vault.totalAssets();
        assertGt(vaultAssetsAfter, vaultAssetsBefore, "vault should capture Aave yield");
        assertApproxEqAbs(vaultAssetsAfter, aTokenAfter, 2, "vault should capture nearly all of the yield");

        // The adapter's reported value agrees with the vault.
        assertApproxEqAbs(aaveStrategy.realAssets(), aTokenAfter, 2, "adapter real assets mismatch");

        // Yield raises the per-share value; share count is unchanged.
        uint256 shareValueAfter = vault.previewRedeem(vault.balanceOf(user));
        assertGt(shareValueAfter, shareValueBefore, "share value should increase with yield");
        assertGe(shareValueAfter, depositAmount, "share value should not fall below principal");
    }

    /* ========== KILL SWITCH ========== */

    function testKillSwitchPausesInflowsButNotOutflows() public {
        uint256 depositAmount = 10_000e6;

        vm.prank(user);
        vault.deposit(depositAmount, user);

        // Trip the kill switch.
        vm.prank(strategyOwner);
        aaveStrategy.setKillSwitch(true);
        assertTrue(aaveStrategy.killSwitch());

        // New deposits revert because allocation is paused.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.StrategyAllocationPaused.selector, address(aaveStrategy)));
        vault.deposit(depositAmount, user);

        // Existing depositors can still exit: deallocation is not gated by the kill switch.
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        vault.withdraw(depositAmount / 2, user, user);
        assertEq(asset.balanceOf(user) - balanceBefore, depositAmount / 2, "withdrawal blocked during kill switch");

        // Clearing the kill switch restores deposits.
        vm.prank(strategyOwner);
        aaveStrategy.setKillSwitch(false);
        vm.prank(user);
        uint256 shares = vault.deposit(depositAmount, user);
        assertGt(shares, 0, "deposit still blocked after clearing kill switch");
    }

    /* ========== ADMIN / SAFETY ========== */

    function testProtectedTokensCannotBeRescued() public {
        vm.startPrank(strategyOwner);
        vm.expectRevert(bytes("Protected token"));
        aaveStrategy.rescueTokens(address(asset), strategyOwner, 1);

        vm.expectRevert(bytes("Protected token"));
        aaveStrategy.rescueTokens(address(aToken), strategyOwner, 1);
        vm.stopPrank();
    }

    function testRescueUnprotectedToken() public {
        ERC20Mock stray = new ERC20Mock(18);
        deal(address(stray), address(aaveStrategy), 100e18);

        vm.prank(strategyOwner);
        aaveStrategy.rescueTokens(address(stray), strategyOwner, 100e18);

        assertEq(stray.balanceOf(strategyOwner), 100e18, "stray token not rescued");
        assertEq(stray.balanceOf(address(aaveStrategy)), 0);
    }

    function testWithdrawLeftoverToVault() public {
        // Simulate dust/leftover asset sitting idle on the strategy.
        uint256 leftover = 500e6;
        deal(address(asset), address(aaveStrategy), leftover);

        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));

        vm.prank(strategyOwner);
        uint256 moved = aaveStrategy.withdrawToVault();

        assertEq(moved, leftover, "wrong leftover amount reported");
        assertEq(asset.balanceOf(address(vault)) - vaultBalanceBefore, leftover, "leftover not sent to vault");
        assertEq(asset.balanceOf(address(aaveStrategy)), 0, "strategy still holds idle asset");
    }

    function testSetSlippageBPS() public {
        vm.prank(strategyOwner);
        aaveStrategy.setSlippageBPS(200);

        uint256 amount = 10_000e6;
        assertEq(aaveStrategy.previewAdjustedWithdraw(amount), amount - (amount * 200 / 10_000), "slippage not updated");
    }

    function testClaimRewardsWithNoActiveRewards() public {
        // The supported markets pay no liquidity-mining rewards at this block: claiming is a no-op.
        vm.prank(strategyOwner);
        uint256 claimed = aaveStrategy.claimRewards(address(aToken), "", 0);
        assertEq(claimed, 0, "unexpected rewards claimed");

        // Claiming is blocked while the kill switch is engaged.
        vm.prank(strategyOwner);
        aaveStrategy.setKillSwitch(true);
        vm.prank(strategyOwner);
        vm.expectRevert(bytes("emergency"));
        aaveStrategy.claimRewards(address(aToken), "", 0);
    }

    function testOnlyOwnerAdminFunctions() public {
        address notOwner = makeAddr("notOwner");
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner);

        vm.startPrank(notOwner);
        vm.expectRevert(unauthorized);
        aaveStrategy.setKillSwitch(true);

        vm.expectRevert(unauthorized);
        aaveStrategy.setSlippageBPS(100);

        vm.expectRevert(unauthorized);
        aaveStrategy.rescueTokens(address(0x1234), notOwner, 1);

        vm.expectRevert(unauthorized);
        aaveStrategy.claimRewards(address(aToken), "", 0);

        vm.expectRevert(unauthorized);
        aaveStrategy.adminDexSwap(address(asset), REWARD_TOKEN, 1, 0, "");
        vm.stopPrank();
    }
}
