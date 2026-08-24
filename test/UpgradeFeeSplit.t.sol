// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Yield} from "../src/Yield.sol";
import {Manager} from "../src/Manager.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {TownSqTokenV1} from "./legacy/TownSqTokenV1.sol";
import {YieldV1} from "./legacy/YieldV1.sol";

/**
 * @title UpgradeFeeSplitTest
 * @notice Live-fire test of the fee-split upgrade against state built by the CURRENTLY
 *         DEPLOYED implementations, which are vendored verbatim in test/legacy.
 *
 *         The storage-layout diff already proves the slots match. What this covers is what a
 *         layout diff cannot: that the swap happens mid-vesting without disturbing an
 *         in-flight schedule, that the share price does not move across the upgrade itself,
 *         that the first post-upgrade epoch no longer steps the price up, and that the
 *         upgrade ORDER is load-bearing.
 *
 *         MAINTENANCE: test/legacy holds the implementation live at commit b6e5b5c. Once this
 *         upgrade is deployed those files describe the PREVIOUS deployment, and this suite
 *         keeps passing while no longer testing anything about the next upgrade. Re-vendor
 *         from the live commit first — see test/legacy/README.md.
 *
 *         Run with: forge test --match-contract UpgradeFeeSplitTest -vv
 */
contract UpgradeFeeSplitTest is Test {
    MockERC20 internal asset;
    Manager internal manager;

    // Held as V1 types until the upgrade, then re-cast.
    TownSqTokenV1 internal vaultV1;
    YieldV1 internal yieldV1;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");

    uint256 internal constant DEPOSIT_AMOUNT = 100_000e6;
    uint256 internal constant VESTING_PERIOD = 7 days;

    /// @dev Everything a logic-only upgrade must leave untouched.
    struct VaultState {
        uint256 cooldownPeriod;
        uint256 vestingPeriod;
        uint256 vestingAmount;
        uint256 lastDistributionTimestamp;
        uint256 fee;
        uint256 virtualAssets;
        uint256 totalRequestedAmount;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 treasuryShares;
        uint256 aliceShares;
        uint256 unvested;
    }

    function setUp() public {
        vm.startPrank(admin);
        asset = new MockERC20("USD Coin", "USDC");

        yieldV1 = YieldV1(
            address(new townSqProxy(address(new YieldV1()), abi.encodeCall(YieldV1.initialize, (admin, rebalancer))))
        );
        manager = Manager(
            address(
                new townSqProxy(
                    address(new Manager()), abi.encodeCall(Manager.initialize, (admin, address(yieldV1), operator))
                )
            )
        );
        vaultV1 = TownSqTokenV1(
            address(
                new townSqProxy(
                    address(new TownSqTokenV1()),
                    abi.encodeCall(
                        TownSqTokenV1.initialize,
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
        manager.setManagerAndYield(address(yieldV1), address(vaultV1));
        manager.setMinSharesInVaultToken(address(vaultV1), 1e6);
        manager.setMaxRedeemCap(address(vaultV1), type(uint256).max);
        yieldV1.setManager(address(manager));
        vm.stopPrank();

        asset.mint(alice, DEPOSIT_AMOUNT);
        vm.startPrank(alice);
        asset.approve(address(vaultV1), type(uint256).max);
        vaultV1.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
    }

    /// @dev The upgrade lands mid-schedule: state preserved, price continuous across the swap,
    ///      the in-flight schedule completes, and the next epoch no longer steps the price up.
    function test_Upgrade_MidVesting_PreservesStateAndRemovesTheStep() public {
        // ---- epoch 1 on the DEPLOYED implementations, left half-vested ----
        skip(1 days);
        vm.prank(rebalancer);
        yieldV1.distributeYield(400e6, 100e6, 1, true);
        skip(VESTING_PERIOD / 2);

        assertGt(vaultV1.getUnvestedAmount(), 0, "a schedule must be in flight at upgrade time");

        VaultState memory before = _snapshot();
        uint256 unit = 10 ** vaultV1.decimals();
        uint256 ppsBefore = vaultV1.convertToAssets(unit);

        // ---- the upgrade: token implementation FIRST, then yield ----
        _upgrade();

        TownSqToken vault = TownSqToken(address(vaultV1));
        Yield yieldC = Yield(address(yieldV1));

        // Nothing moved. Each of these reads a storage slot through the new implementation.
        _assertPreserved(before, _snapshot());
        assertEq(vault.convertToAssets(unit), ppsBefore, "share price moved across the upgrade");
        assertEq(yieldC.epoch(), 1, "epoch survived the yield upgrade");

        // ---- the in-flight schedule still completes correctly ----
        uint256 assetsAtUpgrade = vault.totalAssets();
        skip(VESTING_PERIOD); // finish epoch 1's schedule
        assertEq(vault.getUnvestedAmount(), 0, "the pre-upgrade schedule completed");
        assertEq(
            vault.totalAssets(), assetsAtUpgrade + before.unvested, "the pre-upgrade unvested balance was recognised"
        );

        // ---- epoch 2, now on the new implementations: no upward step ----
        uint256 ppsPreEpoch2 = vault.convertToAssets(unit);
        uint256 treasurySharesPreEpoch2 = vault.balanceOf(treasury);
        vm.prank(rebalancer);
        yieldC.distributeYield(400e6, 100e6, 2, true);
        uint256 ppsPostEpoch2 = vault.convertToAssets(unit);

        console2.log("pps before epoch 2 :", ppsPreEpoch2);
        console2.log("pps after  epoch 2 :", ppsPostEpoch2);

        assertLe(ppsPostEpoch2, ppsPreEpoch2, "post-upgrade epoch must not step the price up");
        assertGe(ppsPostEpoch2 + 2, ppsPreEpoch2, "and must not drop beyond rounding dust");

        // The treasury is still paid in full, just on the shared schedule. Valued on the
        // NEWLY MINTED shares only: the treasury's pre-existing epoch-1 shares also earn
        // epoch-2 yield, exactly as any other holder's do, and that is not fee.
        uint256 feeShares = vault.balanceOf(treasury) - treasurySharesPreEpoch2;
        skip(VESTING_PERIOD);
        uint256 feeValue = vault.convertToAssets(feeShares);
        console2.log("epoch 2 fee shares are worth:", feeValue);
        assertApproxEqAbs(feeValue, 100e6, 1e3, "the treasury still collects its whole fee");
    }

    /// @dev The pre-upgrade epoch DID step the price up — the bug this upgrade removes. Shown
    ///      on the deployed implementations so the fix has a measured baseline.
    function test_Upgrade_DeployedImplementationStepsThePriceUp() public {
        skip(1 days);
        uint256 unit = 10 ** vaultV1.decimals();
        uint256 ppsBefore = vaultV1.convertToAssets(unit);

        vm.prank(rebalancer);
        yieldV1.distributeYield(400e6, 100e6, 1, true);

        uint256 ppsAfter = vaultV1.convertToAssets(unit);
        console2.log("V1 pps before:", ppsBefore);
        console2.log("V1 pps after :", ppsAfter);

        assertGt(ppsAfter, ppsBefore, "the deployed implementation steps the price up");
    }

    /// @dev ORDERING: upgrading Yield while the token is still V1 bricks profit distributions,
    ///      because the new Yield calls `previewProfitFee`, which V1 does not implement. This
    ///      is why the runbook must swap the token implementation first.
    function test_Upgrade_YieldBeforeTokenBricksProfitDistribution() public {
        vm.startPrank(admin);
        yieldV1.upgradeToAndCall(address(new Yield()), "");
        vm.stopPrank();

        skip(1 days);
        vm.prank(rebalancer);
        vm.expectRevert();
        Yield(address(yieldV1)).distributeYield(400e6, 100e6, 1, true);

        // A zero-fee distribution still works — the new code path is only reached when a fee
        // is charged, so the break is silent until the first fee-bearing epoch.
        vm.prank(rebalancer);
        Yield(address(yieldV1)).distributeYield(400e6, 0, 1, true);
        assertEq(Yield(address(yieldV1)).epoch(), 1, "zero-fee epochs mask the missing function");
    }

    /// @dev And the correct order has no broken window: the token upgrade alone changes nothing,
    ///      because V1 Yield never calls the new function.
    function test_Upgrade_TokenFirstLeavesNoBrokenWindow() public {
        // Deploy outside the prank: `new` would otherwise consume it and the upgrade call
        // would come from the test contract, which holds no admin role.
        address newTokenImpl = address(new TownSqToken());
        vm.prank(admin);
        vaultV1.upgradeToAndCall(newTokenImpl, "");

        skip(1 days);
        vm.prank(rebalancer);
        yieldV1.distributeYield(400e6, 100e6, 1, true);

        assertEq(yieldV1.epoch(), 1, "V1 yield keeps working against the new token");
    }

    // ============ helpers ============

    function _upgrade() internal {
        vm.startPrank(admin);
        // Token first: the new Yield depends on a function only the new token provides.
        vaultV1.upgradeToAndCall(address(new TownSqToken()), "");
        yieldV1.upgradeToAndCall(address(new Yield()), "");
        vm.stopPrank();
    }

    function _snapshot() internal view returns (VaultState memory s) {
        s.cooldownPeriod = vaultV1.cooldownPeriod();
        s.vestingPeriod = vaultV1.vestingPeriod();
        s.vestingAmount = vaultV1.vestingAmount();
        s.lastDistributionTimestamp = vaultV1.lastDistributionTimestamp();
        s.fee = vaultV1.fee();
        s.virtualAssets = vaultV1.virtualAssets();
        s.totalRequestedAmount = vaultV1.totalRequestedAmount();
        s.totalSupply = vaultV1.totalSupply();
        s.totalAssets = vaultV1.totalAssets();
        s.treasuryShares = vaultV1.balanceOf(treasury);
        s.aliceShares = vaultV1.balanceOf(alice);
        s.unvested = vaultV1.getUnvestedAmount();
    }

    function _assertPreserved(VaultState memory a, VaultState memory b) internal pure {
        assertEq(a.cooldownPeriod, b.cooldownPeriod, "cooldownPeriod");
        assertEq(a.vestingPeriod, b.vestingPeriod, "vestingPeriod");
        assertEq(a.vestingAmount, b.vestingAmount, "vestingAmount");
        assertEq(a.lastDistributionTimestamp, b.lastDistributionTimestamp, "lastDistributionTimestamp");
        assertEq(a.fee, b.fee, "fee");
        assertEq(a.virtualAssets, b.virtualAssets, "virtualAssets");
        assertEq(a.totalRequestedAmount, b.totalRequestedAmount, "totalRequestedAmount");
        assertEq(a.totalSupply, b.totalSupply, "totalSupply");
        assertEq(a.totalAssets, b.totalAssets, "totalAssets");
        assertEq(a.treasuryShares, b.treasuryShares, "treasuryShares");
        assertEq(a.aliceShares, b.aliceShares, "aliceShares");
        assertEq(a.unvested, b.unvested, "unvested");
    }
}
