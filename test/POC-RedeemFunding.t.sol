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
 * @title RedeemFundingPoC
 * @notice Confirms whether the vault must be explicitly funded before a redemption can
 *         settle, given that deposits are custodied by the Manager rather than the vault.
 *
 *         Run with: forge test --match-contract RedeemFundingPoC -vv
 */
contract RedeemFundingPoC is Test {
    MockERC20 internal asset;
    townSqToken internal vault;
    Manager internal manager;
    Yield internal yield;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");
    address internal randomAddr = makeAddr("randomAddr");

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
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
        vm.stopPrank();

        asset.mint(alice, DEPOSIT_AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /// @dev requestRedeem does NOT move any assets -- it only records the claim.
    function test_RequestRedeem_MovesNoAssets() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        assertEq(asset.balanceOf(address(vault)), 0, "vault still holds nothing after the request");
        assertEq(asset.balanceOf(address(manager)), DEPOSIT_AMOUNT, "assets stay in the Manager");
        assertEq(vault.totalRequestedAmount(), DEPOSIT_AMOUNT, "only the pending-claim counter moved");
    }

    /// @dev THE ANSWER: yes. Even with the assets sitting in the Manager, redeem reverts
    ///      until they are moved INTO the vault. `_withdraw` transfers from the vault's own
    ///      balance and has no ability to pull from the Manager.
    function test_Redeem_RevertsWhenVaultUnfunded_EvenThoughManagerHoldsAssets() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);

        skip(COOLDOWN_PERIOD);

        // Cooldown is over and the protocol demonstrably holds the money...
        assertTrue(vault.canExecuteRedeem(alice), "cooldown satisfied");
        assertEq(asset.balanceOf(address(manager)), DEPOSIT_AMOUNT, "Manager is holding Alice's assets");

        // ...but the redemption still fails, because the VAULT holds nothing.
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance on the vault
        vault.redeem(shares, alice, alice);

        assertEq(asset.balanceOf(alice), 0, "Alice got nothing");
    }

    /// @dev The funding step unblocks it. transferToVault is OPERATOR_ROLE gated.
    function test_Redeem_SucceedsAfterOperatorFundsVault() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);
        (, uint256 owed,,) = vault.getRedeemRequest(alice);

        skip(COOLDOWN_PERIOD);

        vm.prank(operator);
        manager.transferToVault(address(asset), owed);
        assertEq(asset.balanceOf(address(vault)), owed, "vault is now funded");

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(asset.balanceOf(alice), owed, "Alice paid out");
    }

    /// @dev transferToVault is not privileged from the vault's perspective -- the vault just
    ///      reads its own balance. A plain ERC-20 transfer from anyone funds it just as well.
    function test_Redeem_AnyPlainTransferFundsTheVault() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);
        (, uint256 owed,,) = vault.getRedeemRequest(alice);

        skip(COOLDOWN_PERIOD);

        // A completely unrelated address sends the tokens in.
        asset.mint(randomAddr, owed);
        vm.prank(randomAddr);
        asset.transfer(address(vault), owed);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(asset.balanceOf(alice), owed, "redemption settles from whatever the vault holds");
    }

    /// @dev redeemFor (Manager-only, skips cooldown) has the same funding requirement.
    function test_RedeemFor_AlsoRequiresFundedVault() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares);
        (, uint256 owed,,) = vault.getRedeemRequest(alice);

        vm.prank(operator);
        vm.expectRevert(); // unfunded vault, even though redeemFor bypasses the cooldown
        manager.redeemFor(address(vault), alice);

        vm.prank(operator);
        manager.transferToVault(address(asset), owed);

        vm.prank(operator);
        manager.redeemFor(address(vault), alice);
        assertEq(asset.balanceOf(alice), owed, "settles once funded");
    }
}
