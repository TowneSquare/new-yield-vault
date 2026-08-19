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
 * @title ExitFeeTest
 * @notice Covers the exit-only fee: no charge on entry, and the fee on redemption is minted
 *         to the treasury rather than accruing implicitly to the remaining holders.
 */
contract ExitFeeTest is Test {
    MockERC20 internal asset;
    TownSqToken internal vault;
    Manager internal manager;
    Yield internal yield;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant HUNDRED_PERCENT = 100e18;
    uint256 internal constant FEE = 1e18; // 1% -- the maximum allowed

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
                            1 days
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
        vault.setFee(FEE);
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

    /// @dev Entry is free: the depositor keeps every share and the treasury gets nothing.
    function test_Deposit_ChargesNoFee() public view {
        assertEq(vault.balanceOf(treasury), 0, "treasury earns nothing on deposits");
        assertEq(vault.previewDeposit(DEPOSIT_AMOUNT), vault.convertToShares(DEPOSIT_AMOUNT), "no fee on entry");
        // Alice put in 1,000 and can redeem ~1,000 less only the exit fee.
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), (DEPOSIT_AMOUNT * 99) / 100, "1% exit fee only");
    }

    /// @dev The exit fee lands in the treasury as shares.
    function test_RequestRedeem_MintsFeeSharesToTreasury() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 expectedFeeShares = (shares * FEE) / HUNDRED_PERCENT;

        vm.prank(alice);
        vault.requestRedeem(shares);

        assertEq(vault.balanceOf(alice), 0, "all of Alice's shares burned");
        assertEq(vault.balanceOf(treasury), expectedFeeShares, "treasury holds the 1% exit fee");
        assertGt(expectedFeeShares, 0, "fee is non-trivial");

        console2.log("Alice shares redeemed :", shares);
        console2.log("Treasury fee shares   :", vault.balanceOf(treasury));
    }

    /// @dev The share price is exactly neutral for holders who stay -- the fee is a treasury
    ///      claim, not a windfall redistributed to remaining holders.
    function test_RequestRedeem_SharePriceNeutralForRemainingHolders() public {
        uint256 priceBefore = vault.convertToAssets(1e18);
        uint256 bobValueBefore = vault.convertToAssets(vault.balanceOf(bob));

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        uint256 priceAfter = vault.convertToAssets(1e18);

        console2.log("share price before :", priceBefore);
        console2.log("share price after  :", priceAfter);

        assertEq(priceAfter, priceBefore, "exit fee does not move the share price");
        assertEq(vault.convertToAssets(vault.balanceOf(bob)), bobValueBefore, "Bob is unaffected");
    }

    /// @dev With no fee configured, nothing is minted and the flow is unchanged.
    function test_RequestRedeem_NoFee_MintsNothing() public {
        vm.prank(admin);
        vault.setFee(0);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        assertEq(vault.balanceOf(treasury), 0, "no fee, no treasury shares");
        (, uint256 owed,,) = vault.getRedeemRequest(alice);
        assertEq(owed, DEPOSIT_AMOUNT, "full value returned when fee is zero");
    }
}
