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
 * @title TotalAssetsUnderflowPoC
 * @notice Investigates KNOWN_ISSUES.md Q-03: can `totalAssets()` be made to underflow?
 *
 *         `totalAssets()` returns `virtualAssets - getUnvestedAmount()`. Losses reduce
 *         `virtualAssets` but never reduce `vestingAmount`, so the concern was that a loss
 *         booked while a large amount is unvested could drive `getUnvestedAmount()` above
 *         `virtualAssets` and make `totalAssets()` revert — bricking `previewDeposit`,
 *         `previewRedeem` and `distributeYield` together.
 *
 *         CONCLUSION: not reachable. Every path that subtracts from `virtualAssets` is
 *         bounded by a quantity that is itself <= the current gap
 *         (`gap == totalAssets() == virtualAssets - unvested`), so the gap converges to
 *         zero without crossing it. The tests below demonstrate each bound.
 *
 *         Run with: forge test --match-contract TotalAssetsUnderflowPoC -vv
 */
contract TotalAssetsUnderflowPoC is Test {
    MockERC20 internal asset;
    TownSqToken internal vault;
    Manager internal manager;
    Yield internal yield;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant VESTING_PERIOD = 30 days; // maximum, to keep unvested high
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

        asset.mint(alice, DEPOSIT_AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /// @dev Establishes a large unvested balance and treasury share position, then reports
    ///      the gap that a loss would have to exceed.
    function _seedVestingAndTreasury(uint256 profit, uint256 feeAmount) internal {
        // The default cap (maxYieldPercentage == 50, i.e. 0.5% of totalAssets) is far too
        // tight to seed a meaningful vesting balance, so open it for the seeding step only.
        // NOTE: exceeding it reverts via a bare `require()` with no message — see Q-05.
        vm.startPrank(admin);
        yield.setMaxYieldPercentage(10_000);
        yield.setMaxFeePercentage(10_000);
        vm.stopPrank();

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(profit, feeAmount, 1, true);

        // Restore defaults; individual tests widen them again as needed.
        vm.startPrank(admin);
        yield.setMaxYieldPercentage(50);
        yield.setMaxFeePercentage(5_000);
        vm.stopPrank();
    }

    /// @dev The invariant that holds throughout: virtualAssets >= getUnvestedAmount().
    function _assertNoUnderflow() internal view {
        assertGe(vault.virtualAssets(), vault.getUnvestedAmount(), "virtualAssets fell below unvested");
        vault.totalAssets(); // must not revert
    }

    /// @dev At default parameters (maxYield 0.5%, maxFee 50%) the loss path is bounded well
    ///      below the gap, so repeated maximum losses shrink the gap geometrically and can
    ///      never close it. `totalAssets()` stays callable throughout.
    function test_Underflow_LossPathIsSelfLimitingAtDefaults() public {
        _seedVestingAndTreasury(500e6, 100e6);

        uint256 gapBefore = vault.totalAssets();
        console2.log("unvested after profit :", vault.getUnvestedAmount());
        console2.log("gap (totalAssets)     :", gapBefore);

        // Book the maximum permitted loss repeatedly, staying inside the vesting window.
        for (uint256 i = 0; i < 20; i++) {
            skip(23 hours); // clears minDistributionInterval (79200s == 22h)
            uint256 gap = vault.totalAssets();
            uint256 maxLoss = gap * yield.maxYieldPercentage() / 10_000;
            if (maxLoss == 0) break;

            vm.prank(rebalancer);
            yield.distributeYield(maxLoss, 0, i + 2, false);

            _assertNoUnderflow();
        }

        // The gap ENDS UP LARGER than it started: 20 rounds of 23h releases most of the
        // 30-day vesting schedule, and that released yield outpaces the 0.5%-capped losses.
        // The point is not the direction of travel but that `_assertNoUnderflow` held every
        // round — the loss path can never subtract more than the gap it is measured against.
        console2.log("gap after 20 max losses:", vault.totalAssets());
        assertGt(vault.totalAssets(), 0, "gap never closed at default parameters");
    }

    /// @dev The only way to subtract MORE than the gap in one distribution is the loss-fee
    ///      path, which subtracts `amount + feeAmount`. This used to revert, because burning
    ///      that much from the treasury required more shares than exist. It no longer does:
    ///      the burn is now CLAMPED to the treasury's actual balance and the uncovered
    ///      remainder is booked as `treasuryDebt`, so a loss report can always be recorded
    ///      even when the treasury cannot absorb its share. The invariant that matters is
    ///      unchanged and is what this now asserts — the gap is never crossed.
    function test_Underflow_FeeBurnClampsInsteadOfReverting() public {
        _seedVestingAndTreasury(500e6, 100e6);

        // Admin opens the caps as wide as they go.
        vm.startPrank(admin);
        yield.setMaxYieldPercentage(6_000); // 60% of totalAssets
        yield.setMaxFeePercentage(10_000); // fee may equal amount
        vm.stopPrank();

        skip(23 hours);

        uint256 gap = vault.totalAssets();
        uint256 amount = gap * 6_000 / 10_000; // 60% of the gap
        uint256 feeAmount = amount; // amount + feeAmount == 120% of the gap

        assertGt(amount + feeAmount, gap, "combined subtraction does exceed the gap");
        console2.log("gap                :", gap);
        console2.log("amount + feeAmount :", amount + feeAmount);
        console2.log("treasury shares    :", vault.balanceOf(treasury));
        console2.log("total supply       :", vault.totalSupply());

        uint256 treasurySharesBefore = vault.balanceOf(treasury);
        uint256 debtBefore = yield.treasuryDebt();

        // Records successfully rather than reverting: the burn clamps, the rest becomes debt.
        vm.prank(rebalancer);
        yield.distributeYield(amount, feeAmount, 2, false);

        // The invariant this file exists to defend still holds.
        _assertNoUnderflow();

        // And the clamp behaved as designed: the treasury gave up everything it had, and the
        // part it could not cover was booked as an obligation instead of silently socialised.
        assertEq(vault.balanceOf(treasury), 0, "treasury shares fully consumed by the clamp");
        assertGt(yield.treasuryDebt(), debtBefore, "the uncovered remainder is booked as debt");
        console2.log("treasury shares burned :", treasurySharesBefore);
        console2.log("treasuryDebt accrued   :", yield.treasuryDebt() - debtBefore);
    }

    /// @dev `requestRedeem` also subtracts from `virtualAssets`, but the amount comes from
    ///      `previewRedeem`, which is proportional to the gap — so even redeeming the entire
    ///      supply cannot drive it negative.
    function test_Underflow_FullRedeemRequestCannotCloseTheGap() public {
        _seedVestingAndTreasury(500e6, 100e6);

        skip(1 hours);

        // Cache the balance BEFORE pranking — an intervening view call consumes vm.prank.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares);

        _assertNoUnderflow();
        console2.log("gap after full redeem request:", vault.totalAssets());
    }

    /// @dev Belt-and-braces: fuzz the loss schedule inside the vesting window and assert the
    ///      invariant holds for any sequence the caps permit.
    function testFuzz_Underflow_LossSequenceNeverUnderflows(uint256 profit, uint16 lossBps, uint8 rounds) public {
        // Capped at the deposited principal: with maxYieldPercentage at 100%, a single
        // distribution may not exceed totalAssets().
        profit = bound(profit, 1e6, DEPOSIT_AMOUNT);
        lossBps = uint16(bound(lossBps, 1, 10_000));
        rounds = uint8(bound(rounds, 1, 15));

        _seedVestingAndTreasury(profit, 0);

        vm.prank(admin);
        yield.setMaxYieldPercentage(lossBps);

        for (uint256 i = 0; i < rounds; i++) {
            skip(23 hours);
            uint256 maxLoss = vault.totalAssets() * lossBps / 10_000;
            if (maxLoss == 0) break;

            vm.prank(rebalancer);
            yield.distributeYield(maxLoss, 0, i + 2, false);

            _assertNoUnderflow();
        }
    }
}
