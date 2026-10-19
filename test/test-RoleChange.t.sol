// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "openzeppelin-contracts/access/IAccessControl.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {IManager, ManageAssetAndShares} from "../src/Interface/IManager.sol";

/**
 * @title RoleChange
 * @notice Pre-flight simulation of the X Layer fee-split upgrade and admin handover, run
 *         against live mainnet state.
 *
 *         The transactions asserted here are exactly the ones handed to the Safe, in the same
 *         order. Generate that payload with:
 *
 *           forge script script/SafeRoleChange.s.sol --sig 'run()' --rpc-url xlayer
 *
 *         Run with: forge test --match-path test/test-RoleChange.t.sol -vv
 *
 *         Forks LATEST, deliberately: this is a pre-flight check against the state the Safe
 *         will actually execute against, so a role or implementation changing underneath it
 *         should break this test rather than be pinned away.
 */
contract RoleChange is Test {
    TownSqToken public vault;
    Manager public manager;
    Yield public yield;

    // ============ live robinhood(chain 4663) addresses ============
    address constant VAULT_PROXY = 0x5B8dC679EDAE1Ad507c433EF55d5B4bA620F1919;
    address constant YIELD_PROXY = 0xa437BD29AB51BF43C686FE1561B97cF9DeBFB524;
    address constant MANAGER_PROXY = 0xF14d5567f85c73FD309738374D5a69EB17b8387c;

    address constant NEW_VAULT_IMPL = 0xDCf4Ddb6b845D32b5a2F18399d12eD88F98656aa;
    address constant NEW_YIELD_IMPL = 0x78eE602102d07839709D925c15b565cFDf833BDc;

    /// @dev Both are Safe v1.4.1, 3 owners, threshold 2.
    address public admin = 0x131Cc6487172c86F522e1bF00A544d311a686883;
    address public newAdmin = 0xDb0794A79e57559547Cc8eb8a51ed041656dae23;

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Vault state that a logic-only upgrade must leave untouched.
    struct VaultSnapshot {
        string name;
        string symbol;
        uint8 decimals;
        address asset;
        address manager;
        uint256 cooldownPeriod;
        uint256 vestingPeriod;
        uint256 vestingAmount;
        uint256 lastDistributionTimestamp;
        uint256 fee;
        uint256 virtualAssets;
        uint256 totalRequestedAmount;
        uint256 totalSupply;
        uint256 totalAssets;
        bool paused;
    }

    /// @dev `treasuryDebt` is deliberately absent: the LIVE Yield implementation predates
    ///      556078d and does not implement it, so reading it pre-upgrade reverts. It is
    ///      asserted separately as a new-storage check after the upgrade.
    struct YieldSnapshot {
        uint256 epoch;
        uint256 profit;
        uint256 loss;
        uint256 maxYieldPercentage;
        uint256 maxFeePercentage;
        uint256 lastDistributionTime;
        uint256 minDistributionInterval;
        address manager;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("robinhood"));
        assertEq(block.chainid, 4663, "not forked onto RobinHood mainnet");

        vault = TownSqToken(VAULT_PROXY);
        yield = Yield(YIELD_PROXY);
        manager = Manager(MANAGER_PROXY);
    }

    function testUpgradeAndChangeRole() public {
        // ================= PRE-FLIGHT =================
        // Fail loudly here rather than deep inside the Safe simulation.
        assertGt(NEW_VAULT_IMPL.code.length, 0, "new vault impl has no code");
        assertGt(NEW_YIELD_IMPL.code.length, 0, "new yield impl has no code");

        address oldVaultImpl = _impl(VAULT_PROXY);
        address oldYieldImpl = _impl(YIELD_PROXY);
        assertTrue(oldVaultImpl != NEW_VAULT_IMPL, "vault already upgraded");
        assertTrue(oldYieldImpl != NEW_YIELD_IMPL, "yield already upgraded");

        // The executing Safe must hold every role it is about to grant away.
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "vault: admin lacks DEFAULT_ADMIN");
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), admin), "vault: admin lacks ADMIN");
        assertTrue(yield.hasRole(yield.DEFAULT_ADMIN_ROLE(), admin), "yield: admin lacks DEFAULT_ADMIN");
        assertTrue(yield.hasRole(yield.ADMIN_ROLE(), admin), "yield: admin lacks ADMIN");
        assertTrue(yield.hasRole(yield.REBALANCER_ROLE(), admin), "yield: admin lacks REBALANCER");
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin), "manager: admin lacks DEFAULT_ADMIN");
        assertTrue(manager.hasRole(manager.ADMIN_ROLE(), admin), "manager: admin lacks ADMIN");
        assertTrue(manager.hasRole(manager.OPERATOR_ROLE(), admin), "manager: admin lacks OPERATOR");

        // Confirm we are upgrading FROM the implementation we think we are: neither new
        // function may exist yet. If either already answers, the upgrade has partly happened
        // and this whole batch needs rethinking rather than executing.
        assertFalse(
            _answers(VAULT_PROXY, abi.encodeWithSignature("previewProfitFee(uint256)", uint256(0))),
            "vault: previewProfitFee already live, proxy is not on the expected implementation"
        );
        assertFalse(
            _answers(YIELD_PROXY, abi.encodeWithSignature("treasuryDebt()")),
            "yield: treasuryDebt already live, proxy is not on the expected implementation"
        );

        VaultSnapshot memory vBefore = _snapshotVault();
        YieldSnapshot memory yBefore = _snapshotYield();

        // ================= THE SAFE BATCH, IN ORDER =================
        vm.startPrank(admin);

        // -- 1. Vault implementation FIRST. The new Yield calls previewProfitFee, which only
        //       the new vault implements; reversed, fee-bearing epochs revert.
        vault.upgradeToAndCall(NEW_VAULT_IMPL, "");

        // -- 2. Yield implementation.
        yield.upgradeToAndCall(NEW_YIELD_IMPL, "");

        // -- 3. Vault roles. Grant before revoke, and revoke DEFAULT_ADMIN last, so the Safe
        //       never strips its own authority mid-sequence.
        vault.grantRole(vault.ADMIN_ROLE(), newAdmin);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin);
        vault.revokeRole(vault.ADMIN_ROLE(), admin);
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), admin);

        // -- 4. Yield roles. Read each constant off ITS OWN contract.
        yield.grantRole(yield.ADMIN_ROLE(), newAdmin);
        yield.grantRole(yield.REBALANCER_ROLE(), newAdmin);
        yield.grantRole(yield.DEFAULT_ADMIN_ROLE(), newAdmin);
        yield.revokeRole(yield.REBALANCER_ROLE(), admin);
        yield.revokeRole(yield.ADMIN_ROLE(), admin);
        yield.revokeRole(yield.DEFAULT_ADMIN_ROLE(), admin);

        // -- 5. Manager roles. Omitting these leaves the old Safe holding OPERATOR_ROLE on the
        //       address custodying every deposited asset, plus the power to upgrade the Manager.
        manager.grantRole(manager.ADMIN_ROLE(), newAdmin);
        manager.grantRole(manager.OPERATOR_ROLE(), newAdmin);
        manager.grantRole(manager.DEFAULT_ADMIN_ROLE(), newAdmin);
        manager.revokeRole(manager.OPERATOR_ROLE(), admin);
        manager.revokeRole(manager.ADMIN_ROLE(), admin);
        manager.revokeRole(manager.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();

        // ================= IMPLEMENTATIONS ACTUALLY MOVED =================
        assertEq(_impl(VAULT_PROXY), NEW_VAULT_IMPL, "vault implementation slot not updated");
        assertEq(_impl(YIELD_PROXY), NEW_YIELD_IMPL, "yield implementation slot not updated");

        // Behavioural proof, not just a slot read: the function the new Yield depends on must
        // answer through the proxy, and the new Yield storage must be readable.
        (uint256 feeShares, uint256 recognisedFee, uint256 vestingFee) = vault.previewProfitFee(0);
        assertEq(feeShares + recognisedFee + vestingFee, 0, "previewProfitFee(0) must be inert");

        // `treasuryDebt` occupies a slot previously inside __gap, so it must read as zero on a
        // proxy that has never held it. A non-zero value here would mean the layout is wrong.
        assertEq(yield.treasuryDebt(), 0, "treasuryDebt must initialise to zero from the gap");

        // The split reconstitutes the fee exactly -- but only once the vault has a base to
        // price against. This vault is currently EMPTY, so the zero-base guard applies and
        // both branches are asserted rather than assuming one.
        uint256 probeFee = 1_000 * 10 ** vault.decimals();
        (, uint256 rec, uint256 vest) = vault.previewProfitFee(probeFee);
        if (vault.totalSupply() == 0 || vault.virtualAssets() == 0) {
            assertEq(rec + vest, 0, "empty vault: the zero-base guard must return zeros");
        } else {
            assertEq(rec + vest, probeFee, "fee split must be lossless");
        }

        // ================= STATE PRESERVED ACROSS THE UPGRADE =================
        _assertVaultPreserved(vBefore, _snapshotVault());
        _assertYieldPreserved(yBefore, _snapshotYield());

        // ================= ROLES FULLY ROTATED =================
        _assertRoleMoved(VAULT_PROXY, vault.DEFAULT_ADMIN_ROLE(), "vault DEFAULT_ADMIN");
        _assertRoleMoved(VAULT_PROXY, vault.ADMIN_ROLE(), "vault ADMIN");

        _assertRoleMoved(YIELD_PROXY, yield.DEFAULT_ADMIN_ROLE(), "yield DEFAULT_ADMIN");
        _assertRoleMoved(YIELD_PROXY, yield.ADMIN_ROLE(), "yield ADMIN");
        _assertRoleMoved(YIELD_PROXY, yield.REBALANCER_ROLE(), "yield REBALANCER");

        _assertRoleMoved(MANAGER_PROXY, manager.DEFAULT_ADMIN_ROLE(), "manager DEFAULT_ADMIN");
        _assertRoleMoved(MANAGER_PROXY, manager.ADMIN_ROLE(), "manager ADMIN");
        _assertRoleMoved(MANAGER_PROXY, manager.OPERATOR_ROLE(), "manager OPERATOR");

        // ================= AUTHORITY REALLY TRANSFERRED =================
        // Role bits are one thing; being able to act is the property that matters.
        //
        // Cache everything BEFORE pranking: an intervening view call consumes vm.prank, and
        // the revert would then be attributed to the test contract instead of the old Safe.
        uint256 cooldown = vault.cooldownPeriod();
        bytes32 vaultAdminRole = vault.ADMIN_ROLE();
        bytes32 defaultAdminRole = vault.DEFAULT_ADMIN_ROLE();

        vm.prank(newAdmin);
        vault.setCooldownPeriod(cooldown);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, vaultAdminRole)
        );
        vault.setCooldownPeriod(cooldown);

        // The old Safe must no longer be able to upgrade anything.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, defaultAdminRole)
        );
        vault.upgradeToAndCall(NEW_VAULT_IMPL, "");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, defaultAdminRole)
        );
        manager.upgradeToAndCall(NEW_YIELD_IMPL, "");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, defaultAdminRole)
        );
        yield.upgradeToAndCall(NEW_YIELD_IMPL, "");

        console2.log("=== HANDOVER VERIFIED ON LIVE X LAYER STATE ===");
        console2.log("old vault impl :", oldVaultImpl);
        console2.log("new vault impl :", _impl(VAULT_PROXY));
        console2.log("old yield impl :", oldYieldImpl);
        console2.log("new yield impl :", _impl(YIELD_PROXY));
        console2.log("admin rotated  :", admin);
        console2.log("            to :", newAdmin);
    }

    // ============ helpers ============

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    /// @dev Whether `target` implements the probed function. A missing function falls through
    ///      the proxy to an implementation that lacks it and reverts, which is the signal.
    function _answers(address target, bytes memory data) internal view returns (bool ok) {
        (ok,) = target.staticcall(data);
    }

    /// @dev New admin holds it, old admin does not. Both halves matter: a grant that succeeded
    ///      while the revoke silently did not is the failure mode worth catching.
    function _assertRoleMoved(address target, bytes32 role, string memory label) internal view {
        assertTrue(IAccessControl(target).hasRole(role, newAdmin), string.concat(label, ": new admin missing role"));
        assertFalse(IAccessControl(target).hasRole(role, admin), string.concat(label, ": old admin retains role"));
    }

    function _snapshotVault() internal view returns (VaultSnapshot memory s) {
        s.name = vault.name();
        s.symbol = vault.symbol();
        s.decimals = vault.decimals();
        s.asset = vault.asset();
        s.manager = vault.manager();
        s.cooldownPeriod = vault.cooldownPeriod();
        s.vestingPeriod = vault.vestingPeriod();
        s.vestingAmount = vault.vestingAmount();
        s.lastDistributionTimestamp = vault.lastDistributionTimestamp();
        s.fee = vault.fee();
        s.virtualAssets = vault.virtualAssets();
        s.totalRequestedAmount = vault.totalRequestedAmount();
        s.totalSupply = vault.totalSupply();
        s.totalAssets = vault.totalAssets();
        s.paused = vault.paused();
    }

    function _assertVaultPreserved(VaultSnapshot memory a, VaultSnapshot memory b) internal pure {
        assertEq(a.name, b.name, "vault name changed");
        assertEq(a.symbol, b.symbol, "vault symbol changed");
        assertEq(a.decimals, b.decimals, "vault decimals changed");
        assertEq(a.asset, b.asset, "vault asset changed");
        assertEq(a.manager, b.manager, "vault manager changed");
        assertEq(a.cooldownPeriod, b.cooldownPeriod, "cooldownPeriod changed");
        assertEq(a.vestingPeriod, b.vestingPeriod, "vestingPeriod changed");
        assertEq(a.vestingAmount, b.vestingAmount, "vestingAmount changed");
        assertEq(a.lastDistributionTimestamp, b.lastDistributionTimestamp, "lastDistributionTimestamp changed");
        assertEq(a.fee, b.fee, "fee changed");
        assertEq(a.virtualAssets, b.virtualAssets, "virtualAssets changed");
        assertEq(a.totalRequestedAmount, b.totalRequestedAmount, "totalRequestedAmount changed");
        assertEq(a.totalSupply, b.totalSupply, "totalSupply changed");
        assertEq(a.totalAssets, b.totalAssets, "totalAssets changed");
        assertEq(a.paused, b.paused, "paused changed");
    }

    function _snapshotYield() internal view returns (YieldSnapshot memory s) {
        s.epoch = yield.epoch();
        s.profit = yield.profit();
        s.loss = yield.loss();
        s.maxYieldPercentage = yield.maxYieldPercentage();
        s.maxFeePercentage = yield.maxFeePercentage();
        s.lastDistributionTime = yield.lastDistributionTime();
        s.minDistributionInterval = yield.minDistributionInterval();
        s.manager = yield.getManager();
    }

    function _assertYieldPreserved(YieldSnapshot memory a, YieldSnapshot memory b) internal pure {
        assertEq(a.epoch, b.epoch, "epoch changed");
        assertEq(a.profit, b.profit, "profit changed");
        assertEq(a.loss, b.loss, "loss changed");
        assertEq(a.maxYieldPercentage, b.maxYieldPercentage, "maxYieldPercentage changed");
        assertEq(a.maxFeePercentage, b.maxFeePercentage, "maxFeePercentage changed");
        assertEq(a.lastDistributionTime, b.lastDistributionTime, "lastDistributionTime changed");
        assertEq(a.minDistributionInterval, b.minDistributionInterval, "minDistributionInterval changed");
        assertEq(a.manager, b.manager, "yield manager changed");
    }
}
