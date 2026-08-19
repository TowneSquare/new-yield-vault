// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {townSqProxy} from "../src/Proxy.sol";

/**
 * @title FeeSharePricingPoC
 * @notice Profit fee shares are minted while the users' profit is still unvested, so they are
 *         priced at the PRE-profit share price. The treasury therefore receives more shares
 *         than `feeAmount` is worth once the profit is recognised, and captures part of the
 *         holders' profit as it vests.
 *
 *         Claim under test:
 *             treasury value after full vesting == feeAmount + feeAmount*amount/(T + feeAmount)
 *
 *         Run with: forge test --match-contract FeeSharePricingPoC -vv
 */
contract FeeSharePricingPoC is Test {
    MockERC20 internal asset;
    TownSqToken internal vault;
    Manager internal manager;
    Yield internal yield;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");

    uint256 internal constant DEPOSIT_AMOUNT = 100_000e6; // 100k TVL
    uint256 internal constant VESTING_PERIOD = 7 days;

    function setUp() public {
        vm.startPrank(admin);
        asset = new MockERC20("USD Coin", "USDC");

        yield = Yield(
            address(new townSqProxy(address(new Yield()), abi.encodeCall(Yield.initialize, (admin, rebalancer))))
        );
        manager = Manager(
            address(
                new townSqProxy(
                    address(new Manager()), abi.encodeCall(Manager.initialize, (admin, address(yield), operator))
                )
            )
        );
        vault = TownSqToken(
            address(
                new townSqProxy(
                    address(new TownSqToken()),
                    abi.encodeCall(
                        TownSqToken.initialize,
                        (
                            "TownSquare USD",
                            "townSqUSD",
                            IERC20(address(asset)),
                            admin,
                            address(manager),
                            24 hours,
                            VESTING_PERIOD
                        )
                    )
                )
            )
        );

        manager.setTreasury(treasury);
        manager.setManagerAndYield(address(yield), address(vault));
        manager.setMinSharesInVaultToken(address(vault), 1e6);
        manager.setMaxRedeemCap(address(vault), type(uint256).max);
        yield.setManager(address(manager));
        vm.stopPrank();

        asset.mint(alice, DEPOSIT_AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /// @dev The fee shares are minted while the profit is still fully unvested, and are
    ///      deliberately priced against the FULLY VESTED base. So at mint time the treasury
    ///      holds LESS than feeAmount and grows into it as the schedule completes -- the fee
    ///      vests on the same timeline as the profit it was levied on.
    function test_FeeShares_StartBelowTheFeeAndGrowIntoIt() public {
        uint256 amount = 400e6; // 0.4% of TVL, inside maxYieldPercentage
        uint256 feeAmount = 100e6;

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(amount, feeAmount, 1, true);

        assertEq(vault.getUnvestedAmount(), amount, "profit fully unvested at mint time");

        uint256 atMint = vault.convertToAssets(vault.balanceOf(treasury));
        assertLt(atMint, feeAmount, "treasury starts below its fee -- it has not vested yet");

        skip(VESTING_PERIOD);
        uint256 afterVesting = vault.convertToAssets(vault.balanceOf(treasury));

        console2.log("treasury at mint      :", atMint);
        console2.log("treasury after vesting:", afterVesting);

        assertGt(afterVesting, atMint, "it grows as the profit vests");
        assertApproxEqAbs(afterVesting, feeAmount, 2, "and lands exactly on the fee");
    }

    /// @dev REGRESSION: once the profit vests the treasury must be worth exactly feeAmount,
    ///      and the holders must receive the whole of `amount`.
    function test_FeeShares_TreasuryGetsExactlyItsFee() public {
        uint256 amount = 400e6;
        uint256 feeAmount = 100e6;
        uint256 T = vault.totalAssets();

        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(amount, feeAmount, 1, true);
        skip(VESTING_PERIOD); // let it all vest

        uint256 treasuryValue = vault.convertToAssets(vault.balanceOf(treasury));
        uint256 aliceGain = vault.convertToAssets(vault.balanceOf(alice)) - aliceBefore;

        // What the leak WOULD have been without the re-basing fix.
        uint256 leakIfUnfixed = (feeAmount * amount) / (T + feeAmount);

        console2.log("TVL before            :", T);
        console2.log("profit to holders     :", amount);
        console2.log("fee to treasury       :", feeAmount);
        console2.log("--");
        console2.log("treasury value after  :", treasuryValue);
        console2.log("alice gained          :", aliceGain);
        console2.log("leak if unfixed would be:", leakIfUnfixed);

        assertApproxEqAbs(treasuryValue, feeAmount, 2, "treasury gets exactly its fee, no more");
        assertApproxEqAbs(aliceGain, amount, 2, "holders receive the whole profit");
        assertGt(leakIfUnfixed, 1e3, "the scenario is one where the old bug was material");
    }

    /// @dev REGRESSION at the configured maxima -- the worst case for the old mispricing.
    function test_FeeShares_ExactAtMaxYieldAndFee() public {
        uint256 T = vault.totalAssets();
        uint256 amount = (T * yield.maxYieldPercentage()) / 10_000; // the maximum allowed
        uint256 feeAmount = (amount * yield.maxFeePercentage()) / 10_000; // the maximum allowed

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(amount, feeAmount, 1, true);
        skip(VESTING_PERIOD);

        uint256 treasuryValue = vault.convertToAssets(vault.balanceOf(treasury));
        console2.log("max amount   :", amount);
        console2.log("max feeAmount:", feeAmount);
        console2.log("treasury value:", treasuryValue);

        assertApproxEqAbs(treasuryValue, feeAmount, 2, "exact even at the caps");
    }

    /// @dev The case my first formulation got wrong: leftover unvested profit from an earlier
    ///      epoch. Pricing against `totalAssets + amount` would still over-pay here; pricing
    ///      against the fully vested base (virtualAssets) is exact.
    function test_FeeShares_ExactWithPriorEpochStillVesting() public {
        // Epoch 1 -- leave it only part-way through its schedule.
        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(300e6, 0, 1, true);
        skip(VESTING_PERIOD / 2);
        assertGt(vault.getUnvestedAmount(), 0, "epoch 1 is still vesting");

        // Epoch 2 carries a fee while epoch 1's profit is still unrecognised.
        uint256 treasuryBefore = vault.convertToAssets(vault.balanceOf(treasury));
        vm.prank(rebalancer);
        yield.distributeYield(400e6, 100e6, 2, true);

        skip(VESTING_PERIOD); // everything vests
        uint256 gained = vault.convertToAssets(vault.balanceOf(treasury)) - treasuryBefore;

        console2.log("treasury gained:", gained);
        assertApproxEqAbs(gained, 100e6, 1e3, "fee exact despite a prior schedule in flight");
    }

    /// @dev With no fee there is nothing to mispriced, so holders receive the full profit.
    function test_FeeShares_NoFeeMeansNoLeak() public {
        uint256 amount = 400e6;
        uint256 aliceBefore = vault.convertToAssets(vault.balanceOf(alice));

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(amount, 0, 1, true);
        skip(VESTING_PERIOD);

        uint256 aliceGain = vault.convertToAssets(vault.balanceOf(alice)) - aliceBefore;
        assertApproxEqAbs(aliceGain, amount, 2, "alice receives the entire profit");
        assertEq(vault.balanceOf(treasury), 0, "no fee shares exist");
    }
}
