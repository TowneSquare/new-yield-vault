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
 * @title LossVsUnvestedTest
 * @notice A loss must cancel still-unvested profit before it is allowed to move the share
 *         price. Profit that has not vested has been credited to nobody, so destroying it
 *         should cost no holder anything.
 */
contract LossVsUnvestedTest is Test {
    MockERC20 internal asset;
    TownSqToken internal vault;
    Manager internal manager;
    Yield internal yield;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");

    uint256 internal constant DEPOSIT_AMOUNT = 10_000e6;
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

    /// @dev Distribute `p` of profit and advance to the midpoint of its vesting schedule.
    function _profitThenHalfVest(uint256 p, uint256 nonce) internal {
        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(p, 0, nonce, true);
        skip(VESTING_PERIOD / 2);
    }

    /// @dev A loss smaller than the unvested buffer must not move the share price at all.
    ///      Measurements are taken immediately before the loss -- 3.5 days already exceeds
    ///      minDistributionInterval, so no extra skip is needed (one would let more profit
    ///      vest and muddy the comparison).
    function test_LossWithinBuffer_SharePriceUnchanged() public {
        _profitThenHalfVest(50e6, 1);

        uint256 unvestedBefore = vault.getUnvestedAmount();
        uint256 priceBefore = vault.convertToAssets(1e18);
        uint256 assetsBefore = vault.totalAssets();
        assertEq(unvestedBefore, 25e6, "half of the 50 is still unvested");

        vm.prank(rebalancer);
        yield.distributeYield(20e6, 0, 2, false); // 20 loss vs 25 unvested

        assertEq(vault.convertToAssets(1e18), priceBefore, "share price untouched");
        assertEq(vault.totalAssets(), assetsBefore, "totalAssets untouched");

        console2.log("unvested before :", unvestedBefore);
        console2.log("unvested after  :", vault.getUnvestedAmount());
        console2.log("price before    :", priceBefore);
        console2.log("price after     :", vault.convertToAssets(1e18));
    }

    /// @dev The surviving profit still finishes on its ORIGINAL end date -- the clock is not
    ///      restarted, so recognition is not stretched out.
    function test_LossWithinBuffer_PreservesOriginalVestingEnd() public {
        _profitThenHalfVest(50e6, 1);

        // Read the anchor from the contract rather than reconstructing it from timestamps.
        uint256 anchor = vault.lastDistributionTimestamp();
        uint256 scheduleEnd = anchor + VESTING_PERIOD;
        assertEq(vault.getUnvestedAmount(), 25e6, "half the 50 still unvested");

        vm.prank(rebalancer);
        yield.distributeYield(10e6, 0, 2, false);

        // The mechanism: the anchor is untouched and vestingAmount is rescaled instead.
        assertEq(vault.lastDistributionTimestamp(), anchor, "clock NOT restarted");
        assertEq(vault.getUnvestedAmount(), 15e6, "25 unvested less the 10 absorbed");
        assertEq(vault.vestingAmount(), 30e6, "rescaled: 15 remaining over the half-period left");

        // And the consequence: it reaches zero exactly at the original end date, rather than
        // 3.5 days later as it would if the clock had been restarted.
        vm.warp(scheduleEnd - 1);
        assertGt(vault.getUnvestedAmount(), 0, "still vesting one second before the end");

        vm.warp(scheduleEnd);
        assertEq(vault.getUnvestedAmount(), 0, "survivor vests on the ORIGINAL schedule");
    }

    /// @dev A loss larger than the buffer consumes it, and only the excess hits the price.
    function test_LossExceedingBuffer_OnlyExcessHitsPrice() public {
        _profitThenHalfVest(50e6, 1);

        uint256 unvested = vault.getUnvestedAmount();
        uint256 assetsBefore = vault.totalAssets();
        assertEq(unvested, 25e6, "25 of buffer available");

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(40e6, 0, 2, false); // 40 loss vs 25 buffer -> 15 excess

        assertEq(vault.getUnvestedAmount(), 0, "buffer fully consumed");
        assertEq(vault.vestingAmount(), 0, "no schedule left");
        assertEq(vault.totalAssets(), assetsBefore - 15e6, "only the 15 excess hits the price");
    }

    /// @dev With no schedule in flight the loss behaves exactly as before: straight to price.
    function test_NoVestingInFlight_LossHitsPriceDirectly() public {
        uint256 assetsBefore = vault.totalAssets();
        assertEq(vault.getUnvestedAmount(), 0, "nothing vesting");

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(40e6, 0, 1, false);

        assertEq(vault.totalAssets(), assetsBefore - 40e6, "full loss recognised immediately");
    }

    /// @dev Repeated losses each net against whatever buffer survives the previous one.
    ///      Each comparison is taken immediately before its loss, since profit keeps vesting
    ///      in the gaps between distributions.
    function test_SequentialLosses_EachNetsAgainstRemainingBuffer() public {
        _profitThenHalfVest(50e6, 1);
        assertEq(vault.getUnvestedAmount(), 25e6, "25 of buffer");

        uint256 a1 = vault.totalAssets();
        vm.prank(rebalancer);
        yield.distributeYield(10e6, 0, 2, false);
        assertEq(vault.totalAssets(), a1, "first loss fully absorbed");

        skip(1 days);
        uint256 a2 = vault.totalAssets();
        vm.prank(rebalancer);
        yield.distributeYield(5e6, 0, 3, false);
        assertEq(vault.totalAssets(), a2, "second loss fully absorbed");

        // Buffer is nearly exhausted by now; this one bites.
        skip(1 days);
        uint256 a3 = vault.totalAssets();
        vm.prank(rebalancer);
        yield.distributeYield(30e6, 0, 4, false);
        assertLt(vault.totalAssets(), a3, "third loss exceeds what is left");
    }
}
