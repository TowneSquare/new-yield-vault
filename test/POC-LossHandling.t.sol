// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {townSqToken} from "../src/townSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {townSqProxy} from "../src/Proxy.sol";

/**
 * @title LossHandlingPoC
 * @notice Characterises what the protocol actually does when a strategy loses money.
 *         Each test documents one observed behaviour of the `isProfit == false` path.
 *
 *         Run with: forge test --match-contract LossHandlingPoC -vv
 */
contract LossHandlingPoC is Test {
    MockERC20 internal asset;
    townSqToken internal vault;
    Manager internal manager;
    Yield internal yield;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant VESTING_PERIOD = 1 days;
    uint256 internal constant COOLDOWN_PERIOD = 24 hours;

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
        vault = townSqToken(
            address(
                new townSqProxy(
                    address(new townSqToken()),
                    abi.encodeCall(
                        townSqToken.initialize,
                        (
                            "TownSquare USD",
                            "townSqUSD",
                            IERC20(address(asset)),
                            admin,
                            address(manager),
                            COOLDOWN_PERIOD,
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

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            asset.mint(who, DEPOSIT_AMOUNT);
            vm.startPrank(who);
            asset.approve(address(vault), type(uint256).max);
            vault.deposit(DEPOSIT_AMOUNT, who);
            vm.stopPrank();
        }
    }

    /// @dev Losses are applied INSTANTLY — unlike profits, they do not vest.
    function test_Loss_IsAppliedImmediately_NoVesting() public {
        uint256 rateBefore = vault.exchangeRate();
        uint256 assetsBefore = vault.totalAssets();
        uint256 lossAmount = 10e6; // 0.5% of 2,000 == the maxYieldPercentage cap

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(lossAmount, 0, 1, false);

        // No vesting schedule is created and the hit lands in the same block.
        assertEq(vault.vestingAmount(), 0, "no vesting schedule for losses");
        assertEq(vault.getUnvestedAmount(), 0, "nothing is being smoothed");
        assertEq(vault.totalAssets(), assetsBefore - lossAmount, "assets written down immediately");
        assertLt(vault.exchangeRate(), rateBefore, "share price drops in the same block");
        assertEq(yield.loss(), lossAmount, "loss recorded");

        console2.log("rate before loss :", rateBefore);
        console2.log("rate after loss  :", vault.exchangeRate());
    }

    /// @dev On a loss, `feeAmount` is BURNED from the treasury: it claws back fees so the
    ///      treasury absorbs part of the drawdown instead of only ever profiting.
    function test_Loss_BurnsTreasuryShares() public {
        // First a profitable epoch so the treasury actually holds shares to burn.
        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(8e6, 2e6, 1, true);
        skip(VESTING_PERIOD);

        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        assertGt(treasurySharesBefore, 0, "treasury earned fee shares");

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(5e6, 1e6, 2, false);

        assertLt(vault.balanceOf(treasury), treasurySharesBefore, "treasury shares burned to absorb the loss");
        console2.log("treasury shares before loss:", treasurySharesBefore);
        console2.log("treasury shares after loss :", vault.balanceOf(treasury));
    }

    /// @dev A user who requested redemption BEFORE the loss is fully insulated: the asset
    ///      amount is locked in at request time, so remaining holders absorb their share.
    function test_Loss_PendingRedeemersAreInsulated_RemainingHoldersAbsorb() public {
        // Read the balance first: vm.prank applies to the next call, and an inline
        // vault.balanceOf(alice) would consume it before requestRedeem is reached.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares);
        (, uint256 aliceQuote,,) = vault.getRedeemRequest(alice);

        uint256 bobValueBefore = vault.previewRedeem(vault.balanceOf(bob));

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(5e6, 0, 1, false);

        (, uint256 aliceQuoteAfter,,) = vault.getRedeemRequest(alice);
        uint256 bobValueAfter = vault.previewRedeem(vault.balanceOf(bob));

        assertEq(aliceQuoteAfter, aliceQuote, "Alice's locked-in quote is untouched by the loss");
        assertLt(bobValueAfter, bobValueBefore, "Bob absorbs the entire loss");

        console2.log("Alice quote (locked at request):", aliceQuote);
        console2.log("Bob value before loss          :", bobValueBefore);
        console2.log("Bob value after loss           :", bobValueAfter);
        console2.log("Bob's absorbed loss            :", bobValueBefore - bobValueAfter);
    }

    /// @dev A loss cannot be booked in one call if it exceeds maxYieldPercentage of
    ///      totalAssets (0.5% by default) -- large drawdowns must be reported in slices.
    function test_Loss_LargeDrawdownCannotBeReportedAtOnce() public {
        uint256 tenPercentLoss = vault.totalAssets() / 10;

        skip(1 days);
        vm.prank(rebalancer);
        vm.expectRevert();
        yield.distributeYield(tenPercentLoss, 0, 1, false);

        // The cap is 0.5% of totalAssets per epoch, and epochs are rate-limited by
        // minDistributionInterval, so a 10% drawdown takes ~20 epochs to fully book.
        uint256 maxPerEpoch = (vault.totalAssets() * yield.maxYieldPercentage()) / 10_000;
        console2.log("Attempted loss     :", tenPercentLoss);
        console2.log("Max bookable/epoch :", maxPerEpoch);
        console2.log("Epochs required    :", tenPercentLoss / maxPerEpoch);
    }

    /// @dev If the treasury holds fewer shares than the loss fee requires, the whole
    ///      distribution reverts -- loss reporting is blocked until the fee is reduced.
    function test_Loss_RevertsWhenTreasuryHasInsufficientShares() public {
        assertEq(vault.balanceOf(treasury), 0, "treasury starts with no shares");

        skip(1 days);
        vm.prank(rebalancer);
        vm.expectRevert(); // ERC20InsufficientBalance on the treasury burn
        yield.distributeYield(5e6, 1e6, 1, false);

        // Reporting the same loss with a zero fee succeeds.
        vm.prank(rebalancer);
        yield.distributeYield(5e6, 0, 1, false);
        assertEq(yield.loss(), 5e6, "loss booked once the fee is dropped");
    }
}
