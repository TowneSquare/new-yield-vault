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
 * @dev Stand-in for an external yield-generating venue (Aave, a Morpho vault, etc.).
 * The Manager reaches it through the whitelist + `execute` path, exactly as it would a real one.
 */
contract MockStrategy {
    IERC20 public immutable asset;
    uint256 public principal;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function deposit(uint256 amount) external {
        principal += amount;
        asset.transferFrom(msg.sender, address(this), amount);
    }

    /// @dev Withdraws principal plus whatever yield has accrued to this contract.
    function withdrawAll(address to) external returns (uint256 amount) {
        amount = asset.balanceOf(address(this));
        principal = 0;
        asset.transfer(to, amount);
    }
}

/**
 * @title LifecycleProofOfConcept
 * @notice Walks the protocol end to end: user deposit -> capital deployed to an external
 *         protocol -> yield accrues offchain -> yield pushed onchain and vested -> user exits
 *         with a profit. Each phase asserts the state transition it is responsible for.
 *
 *         Run with: forge test --match-contract LifecycleProofOfConcept -vv
 */
contract LifecycleProofOfConcept is Test {
    MockERC20 internal asset;
    TownSqToken internal vault;
    Manager internal manager;
    Yield internal yield;
    MockStrategy internal strategy;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6; // 1,000 USDC (6 decimals)

    // The strategy really earns 5 USDC. `distributeYield` splits that into the users' share
    // and the protocol's cut: NET_YIELD is what vests to shareholders, FEE_AMOUNT is the
    // treasury's slice, and the two must sum to the yield actually funded.
    //   NET_YIELD is capped by maxYieldPercentage (50 bps => 0.5% of totalAssets == 5 USDC)
    //   FEE_AMOUNT is capped by maxFeePercentage  (5000 bps => 50% of NET_YIELD == 2 USDC)
    uint256 internal constant REAL_YIELD = 5e6;
    uint256 internal constant NET_YIELD = 4e6;
    uint256 internal constant FEE_AMOUNT = 1e6;

    uint256 internal constant COOLDOWN_PERIOD = 24 hours;
    uint256 internal constant VESTING_PERIOD = 1 days;

    function setUp() public {
        vm.startPrank(admin);

        asset = new MockERC20("USD Coin", "USDC");

        // ---- deploy implementations + UUPS proxies ----
        TownSqToken vaultImpl = new TownSqToken();
        Manager managerImpl = new Manager();
        Yield yieldImpl = new Yield();

        yield =
            Yield(address(new townSqProxy(address(yieldImpl), abi.encodeCall(Yield.initialize, (admin, rebalancer)))));

        manager = Manager(
            address(
                new townSqProxy(
                    address(managerImpl), abi.encodeCall(Manager.initialize, (admin, address(yield), operator))
                )
            )
        );

        vault = TownSqToken(
            address(
                new townSqProxy(
                    address(vaultImpl),
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

        // ---- wire the three contracts together ----
        manager.setTreasury(treasury);
        manager.setManagerAndYield(address(yield), address(vault));
        manager.setMinSharesInVaultToken(address(vault), 1e6);
        manager.setMaxRedeemCap(address(vault), type(uint256).max);
        yield.setManager(address(manager));

        // ---- whitelist the external venue the Manager is allowed to call ----
        strategy = new MockStrategy(IERC20(address(asset)));
        address[] memory targets = new address[](1);
        bool[] memory statuses = new bool[](1);
        targets[0] = address(strategy);
        statuses[0] = true;
        manager.setWhitelistedAddresses(targets, statuses);

        vm.stopPrank();

        asset.mint(alice, DEPOSIT_AMOUNT);
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_POC_FullLifecycle_DepositToYieldToExit() public {
        // ================= PHASE 1: entry point — Alice deposits =================
        // Note the asset custody model: deposited assets land in the Manager, not the vault.
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        assertEq(vault.balanceOf(alice), shares, "alice holds her shares");
        assertEq(asset.balanceOf(alice), 0, "alice's assets left her wallet");
        assertEq(asset.balanceOf(address(manager)), DEPOSIT_AMOUNT, "Manager custodies the assets");
        assertEq(asset.balanceOf(address(vault)), 0, "vault itself holds nothing");
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "accounting recognises the deposit");

        uint256 rateAfterDeposit = vault.exchangeRate();
        console2.log("");
        console2.log("PHASE 1 - deposit");
        console2.log("  shares minted    :", shares);
        console2.log("  totalAssets      :", vault.totalAssets());
        console2.log("  exchangeRate     :", rateAfterDeposit);

        // ================= PHASE 2: capital deployed to an external protocol =================
        // The operator batches calls through the Manager. Only whitelisted targets are reachable.
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(asset);
        data[0] = abi.encodeCall(IERC20.approve, (address(strategy), DEPOSIT_AMOUNT));
        targets[1] = address(strategy);
        data[1] = abi.encodeCall(MockStrategy.deposit, (DEPOSIT_AMOUNT));

        // `asset` must be whitelisted too — `execute` gates on the target, and the approve
        // is a call to the token itself.
        vm.startPrank(admin);
        address[] memory extra = new address[](1);
        bool[] memory extraStatus = new bool[](1);
        extra[0] = address(asset);
        extraStatus[0] = true;
        manager.setWhitelistedAddresses(extra, extraStatus);
        vm.stopPrank();

        vm.prank(operator);
        manager.execute(targets, data);

        assertEq(asset.balanceOf(address(strategy)), DEPOSIT_AMOUNT, "capital is working in the strategy");
        assertEq(asset.balanceOf(address(manager)), 0, "Manager forwarded everything");
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "deploying capital does not change accounting");

        // ================= PHASE 3: yield accrues offchain =================
        // The strategy earns 5 USDC over a day. Onchain, nothing has happened yet — the vault
        // has no idea it is richer until the offchain engine tells it.
        skip(1 days);
        asset.mint(address(strategy), REAL_YIELD);

        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "vault accounting is still blind to the yield");

        // Operator unwinds the position so the profit is back under Manager custody.
        address[] memory unwindTargets = new address[](1);
        bytes[] memory unwindData = new bytes[](1);
        unwindTargets[0] = address(strategy);
        unwindData[0] = abi.encodeCall(MockStrategy.withdrawAll, (address(manager)));

        vm.prank(operator);
        manager.execute(unwindTargets, unwindData);

        assertEq(
            asset.balanceOf(address(manager)), DEPOSIT_AMOUNT + REAL_YIELD, "principal + yield back in the Manager"
        );

        // ================= PHASE 4: yield pushed onchain and vested =================
        uint256 assetsBeforeDistribution = vault.totalAssets();

        // The 5 USDC earned is split at the call site: 4 vests to shareholders, 1 goes to the
        // treasury as fee shares. NET_YIELD + FEE_AMOUNT must equal what the strategy actually
        // returned, or the vault's books drift from the assets the protocol holds.
        vm.prank(rebalancer);
        yield.distributeYield(NET_YIELD, FEE_AMOUNT, 1, true);

        assertEq(yield.epoch(), 1, "epoch advanced");
        assertEq(vault.vestingAmount(), NET_YIELD, "the users' share is locked in the vesting schedule");
        assertGt(vault.balanceOf(treasury), 0, "treasury was minted fee shares");

        // This is the anti-front-running property: the users' yield is NOT immediately
        // claimable. Only the fee lands instantly, because it is booked as shares, not vested.
        assertEq(
            vault.totalAssets(), assetsBeforeDistribution + FEE_AMOUNT, "t=0: the 4 USDC to users is entirely unvested"
        );
        assertEq(vault.getUnvestedAmount(), NET_YIELD, "nothing has vested yet");
        _log("PHASE 4 - yield pushed", vault.vestingAmount(), vault.totalAssets(), vault.exchangeRate());

        // Halfway through the vesting period, half the users' share has been recognised.
        skip(VESTING_PERIOD / 2);
        assertEq(vault.getUnvestedAmount(), NET_YIELD / 2, "half vested");
        assertEq(
            vault.totalAssets(),
            assetsBeforeDistribution + FEE_AMOUNT + NET_YIELD / 2,
            "half the yield is now recognised"
        );
        _log("PHASE 4 - half vested", vault.getUnvestedAmount(), vault.totalAssets(), vault.exchangeRate());

        // After the full period, all of it is recognised and the share price has risen.
        skip(VESTING_PERIOD / 2);
        assertEq(vault.getUnvestedAmount(), 0, "fully vested");
        assertEq(vault.totalAssets(), assetsBeforeDistribution + REAL_YIELD, "all 5 USDC of yield now recognised");
        assertGt(vault.exchangeRate(), rateAfterDeposit, "share price increased -- this is the yield");

        // SOLVENCY INVARIANT: the books never claim more than the protocol actually holds.
        assertEq(
            vault.totalAssets(),
            asset.balanceOf(address(manager)) + asset.balanceOf(address(vault)),
            "booked assets == real assets under protocol control"
        );
        _log("PHASE 4 - fully vested", 0, vault.totalAssets(), vault.exchangeRate());

        // ================= PHASE 5: exit — request, cooldown, redeem =================
        // Shares burn at request time; the asset amount is locked in at that moment.
        vm.prank(alice);
        vault.requestRedeem(shares);

        (uint256 reqShares, uint256 reqAssets,, bool exists) = vault.getRedeemRequest(alice);
        assertTrue(exists, "request recorded");
        assertEq(reqShares, shares, "all shares requested");
        assertGt(reqAssets, DEPOSIT_AMOUNT, "Alice's claim is worth more than she put in");
        assertEq(vault.balanceOf(alice), 0, "shares burned up front");
        assertFalse(vault.canExecuteRedeem(alice), "cooldown is still running");

        // Offchain engine sources the liquidity into the vault during the cooldown window.
        vm.prank(operator);
        manager.transferToVault(address(asset), reqAssets);

        skip(COOLDOWN_PERIOD);
        assertTrue(vault.canExecuteRedeem(alice), "cooldown elapsed");

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        // ================= RESULT =================
        assertEq(assetsOut, reqAssets, "received exactly what was quoted at request time");
        assertEq(asset.balanceOf(alice), reqAssets, "assets actually landed in Alice's wallet");
        assertGt(asset.balanceOf(alice), DEPOSIT_AMOUNT, "Alice exited with a profit");

        (,,, bool stillExists) = vault.getRedeemRequest(alice);
        assertFalse(stillExists, "request cleared");

        uint256 profit = asset.balanceOf(alice) - DEPOSIT_AMOUNT;
        console2.log("");
        console2.log("=== RESULT ===");
        console2.log("Alice deposited (USDC 1e6):", DEPOSIT_AMOUNT);
        console2.log("Alice withdrew  (USDC 1e6):", asset.balanceOf(alice));
        console2.log("Net profit      (USDC 1e6):", profit);
        console2.log("Treasury fee shares       :", vault.balanceOf(treasury));
    }

    function _log(string memory label, uint256 vesting, uint256 totalAssets, uint256 rate) internal pure {
        console2.log("");
        console2.log(label);
        console2.log("  vesting/unvested :", vesting);
        console2.log("  totalAssets      :", totalAssets);
        console2.log("  exchangeRate     :", rate);
    }
}
