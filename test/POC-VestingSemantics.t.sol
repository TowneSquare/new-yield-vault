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
 * @title VestingSemanticsPoC
 * @notice Characterises what `vestingPeriod` actually does: it smooths recognition of
 *         already-earned yield into the share price. It is NOT a per-user lockup and it
 *         does not delay when a new deposit starts earning.
 *
 *         Run with: forge test --match-contract VestingSemanticsPoC -vv
 */
contract VestingSemanticsPoC is Test {
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
    uint256 internal constant VESTING_PERIOD = 1 days;

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

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            asset.mint(who, DEPOSIT_AMOUNT);
            vm.prank(who);
            asset.approve(address(vault), type(uint256).max);
        }

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, alice);
    }

    /// @dev There is NO per-user waiting period. A depositor's shares are worth more the
    ///      very next second, with no lockup of any kind.
    function test_Vesting_IsNotAPerUserLockup_NewDepositEarnsImmediately() public {
        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(4e6, 0, 1, true); // starts a fresh vesting schedule

        // Bob deposits right at the start of the schedule.
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        uint256 bobValueAtEntry = vault.previewRedeem(vault.balanceOf(bob));

        // One second later he is already worth more. No lockup, no waiting period.
        skip(1);
        assertGt(vault.previewRedeem(vault.balanceOf(bob)), bobValueAtEntry, "Bob earns from the very next second");
    }

    /// @dev What vesting DOES prevent: capturing a lump sum by depositing immediately
    ///      before a distribution. At t=0 the yield is entirely unrecognised.
    function test_Vesting_BlocksInstantCaptureOfALumpSum() public {
        // Bob front-runs the distribution, depositing in the block just before it.
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        uint256 bobValueBefore = vault.previewRedeem(vault.balanceOf(bob));

        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(4e6, 0, 1, true);

        // Same block as the push: Bob captured nothing.
        assertEq(vault.previewRedeem(vault.balanceOf(bob)), bobValueBefore, "no instant windfall for a front-runner");
        assertEq(vault.getUnvestedAmount(), 4e6, "the whole distribution is still unrecognised");
    }

    /// @dev The nuance: vesting SMOOTHS the capture, it does not eliminate it. A depositor
    ///      who enters mid-schedule still shares in yield earned before they arrived.
    function test_Vesting_MidScheduleDepositorStillSharesUnvestedYield() public {
        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(4e6, 0, 1, true);

        skip(VESTING_PERIOD / 2); // half the yield recognised, half still pending

        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        uint256 bobEntryValue = vault.previewRedeem(vault.balanceOf(bob));

        skip(VESTING_PERIOD); // let the remainder vest fully
        uint256 bobFinalValue = vault.previewRedeem(vault.balanceOf(bob));

        console2.log("Bob deposited          :", DEPOSIT_AMOUNT);
        console2.log("Bob value at entry     :", bobEntryValue);
        console2.log("Bob value after vesting:", bobFinalValue);
        console2.log("Captured by Bob        :", bobFinalValue - bobEntryValue);

        // Bob profits from yield the strategies earned before he ever deposited.
        assertGt(bobFinalValue, bobEntryValue, "Bob shares in the still-unvested portion");
        assertGt(bobFinalValue, DEPOSIT_AMOUNT, "Bob ends up ahead of what he put in");
    }

    /// @dev A new distribution rolls any unvested remainder into a fresh schedule and
    ///      RESTARTS the clock -- it does not run two schedules in parallel.
    function test_Vesting_NewDistributionRollsRemainderAndRestartsClock() public {
        skip(1 days);
        vm.prank(rebalancer);
        yield.distributeYield(4e6, 0, 1, true);

        skip(VESTING_PERIOD / 2);
        uint256 unvestedBefore = vault.getUnvestedAmount();
        assertEq(unvestedBefore, 2e6, "half of the first distribution is still pending");

        skip(1 days); // satisfy minDistributionInterval; first schedule fully vests here
        vm.prank(rebalancer);
        yield.distributeYield(4e6, 0, 2, true);

        // The leftover is folded in and the full period starts again from now.
        assertEq(vault.vestingAmount(), 4e6, "remainder (0 by now) + new amount");
        assertEq(vault.lastDistributionTimestamp(), block.timestamp, "clock reset to this moment");

        skip(VESTING_PERIOD);
        assertEq(vault.getUnvestedAmount(), 0, "fully vested a full period after the LATEST push");
    }
}
