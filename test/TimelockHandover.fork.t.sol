// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "openzeppelin-contracts/governance/TimelockController.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {Errors} from "../src/Errors.sol";

/**
 * @title TimelockHandoverFork
 * @notice Pre-flight simulation of the timelock handover against LIVE state.
 *
 *         Deploys the guardian-aware implementations and the TimelockController inside the
 *         fork, then executes exactly the batch that script/TimelockRoleChange.s.sol emits,
 *         in the same order, impersonating the live admin Safe.
 *
 *         Generate the matching payload with:
 *           forge script script/TimelockRoleChange.s.sol --rpc-url robinhood
 *
 *         Run with:
 *           forge test --match-path test/TimelockHandover.fork.t.sol -vv
 *
 *         Forks LATEST deliberately. This is a pre-flight check against the state the Safe
 *         will actually execute against, so a role changing underneath it should break this
 *         test rather than be pinned away.
 *
 *         What this proves that the unit tests cannot:
 *           1. The live proxies accept the new implementations.
 *           2. Live storage survives the upgrade unchanged (fee, cooldown, totalAssets,
 *              supply, epoch all preserved).
 *           3. The live Safe actually holds the roles the batch assumes.
 *           4. After handover, governance is delayed and the guardian path works on the
 *              real deployment.
 */
contract TimelockHandoverFork is Test {
    // ============ live robinhood (chain 4663) addresses ============
    address constant VAULT_PROXY = 0x5B8dC679EDAE1Ad507c433EF55d5B4bA620F1919;
    address constant YIELD_PROXY = 0xa437BD29AB51BF43C686FE1561B97cF9DeBFB524;
    address constant MANAGER_PROXY = 0xF14d5567f85c73FD309738374D5a69EB17b8387c;

    /// @dev Current governance Safe. Overridable via env in case it has rotated again.
    address constant DEFAULT_SAFE = 0xDb0794A79e57559547Cc8eb8a51ed041656dae23;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    uint256 constant MIN_DELAY = 48 hours;

    TownSqToken vault = TownSqToken(VAULT_PROXY);
    Manager manager = Manager(MANAGER_PROXY);
    Yield yield = Yield(YIELD_PROXY);

    TimelockController timelock;
    address safe;

    address newVaultImpl;
    address newManagerImpl;

    /// @dev Live state captured before the upgrade, re-asserted after.
    struct Snapshot {
        uint256 fee;
        uint256 cooldownPeriod;
        uint256 vestingPeriod;
        uint256 virtualAssets;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 totalRequestedAmount;
        address managerRef;
        address treasury;
        uint256 epoch;
        uint256 maxFeePercentage;
    }

    Snapshot internal before;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("robinhood"));

        safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);

        // ---------- the batch's own assumptions, checked up front ----------
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, safe), "safe is not vault DEFAULT_ADMIN - batch would revert");
        assertTrue(manager.hasRole(DEFAULT_ADMIN_ROLE, safe), "safe is not manager DEFAULT_ADMIN");
        assertTrue(yield.hasRole(DEFAULT_ADMIN_ROLE, safe), "safe is not yield DEFAULT_ADMIN");

        before = _snapshot();

        // ---------- deploy what the handover needs ----------
        newVaultImpl = address(new TownSqToken());
        newManagerImpl = address(new Manager());

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.fee = vault.fee();
        s.cooldownPeriod = vault.cooldownPeriod();
        s.vestingPeriod = vault.vestingPeriod();
        s.virtualAssets = vault.virtualAssets();
        s.totalAssets = vault.totalAssets();
        s.totalSupply = vault.totalSupply();
        s.totalRequestedAmount = vault.totalRequestedAmount();
        s.managerRef = vault.manager();
        s.treasury = manager.treasury();
        s.epoch = yield.epoch();
        s.maxFeePercentage = yield.maxFeePercentage();
    }

    /// @dev Exactly the batch from script/TimelockRoleChange.s.sol, in order.
    function _executeHandover() internal {
        vm.startPrank(safe);

        // 1-2: implementations that know GUARDIAN_ROLE
        vault.upgradeToAndCall(newVaultImpl, "");
        manager.upgradeToAndCall(newManagerImpl, "");

        // 3-4: guardian BEFORE any revoke, so there is never a window without a pause path
        vault.grantRole(GUARDIAN_ROLE, safe);
        manager.grantRole(GUARDIAN_ROLE, safe);

        // 5-10: hand governance to the timelock
        vault.grantRole(ADMIN_ROLE, address(timelock));
        vault.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
        manager.grantRole(ADMIN_ROLE, address(timelock));
        manager.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
        yield.grantRole(ADMIN_ROLE, address(timelock));
        yield.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));

        // 11-16: strip the Safe, DEFAULT_ADMIN last on each proxy
        vault.revokeRole(ADMIN_ROLE, safe);
        vault.revokeRole(DEFAULT_ADMIN_ROLE, safe);
        manager.revokeRole(ADMIN_ROLE, safe);
        manager.revokeRole(DEFAULT_ADMIN_ROLE, safe);
        yield.revokeRole(ADMIN_ROLE, safe);
        yield.revokeRole(DEFAULT_ADMIN_ROLE, safe);

        vm.stopPrank();
    }

    // ==================================================================
    // The batch executes at all
    // ==================================================================

    function test_handover_executesAgainstLiveState() public {
        _executeHandover();

        assertTrue(vault.hasRole(ADMIN_ROLE, address(timelock)), "timelock lacks vault ADMIN");
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), "timelock lacks vault DEFAULT_ADMIN");
        assertTrue(manager.hasRole(ADMIN_ROLE, address(timelock)), "timelock lacks manager ADMIN");
        assertTrue(yield.hasRole(ADMIN_ROLE, address(timelock)), "timelock lacks yield ADMIN");

        assertFalse(vault.hasRole(ADMIN_ROLE, safe), "safe retains vault ADMIN");
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, safe), "safe retains vault DEFAULT_ADMIN");
        assertFalse(manager.hasRole(DEFAULT_ADMIN_ROLE, safe), "safe retains manager DEFAULT_ADMIN");
        assertFalse(yield.hasRole(DEFAULT_ADMIN_ROLE, safe), "safe retains yield DEFAULT_ADMIN");

        assertTrue(vault.hasRole(GUARDIAN_ROLE, safe), "safe lacks vault GUARDIAN");
        assertTrue(manager.hasRole(GUARDIAN_ROLE, safe), "safe lacks manager GUARDIAN");
    }

    // ==================================================================
    // Live storage survives the upgrade
    // ==================================================================

    function test_upgrade_preservesLiveStorage() public {
        _executeHandover();
        Snapshot memory afterState = _snapshot();

        assertEq(afterState.fee, before.fee, "fee moved");
        assertEq(afterState.cooldownPeriod, before.cooldownPeriod, "cooldownPeriod moved");
        assertEq(afterState.vestingPeriod, before.vestingPeriod, "vestingPeriod moved");
        assertEq(afterState.virtualAssets, before.virtualAssets, "virtualAssets moved");
        assertEq(afterState.totalAssets, before.totalAssets, "totalAssets moved");
        assertEq(afterState.totalSupply, before.totalSupply, "totalSupply moved");
        assertEq(afterState.totalRequestedAmount, before.totalRequestedAmount, "totalRequestedAmount moved");
        assertEq(afterState.managerRef, before.managerRef, "manager pointer moved");
        assertEq(afterState.treasury, before.treasury, "treasury moved");
        assertEq(afterState.epoch, before.epoch, "epoch moved");
        assertEq(afterState.maxFeePercentage, before.maxFeePercentage, "maxFeePercentage moved");
    }

    function test_upgrade_pointsProxiesAtNewImplementations() public {
        _executeHandover();
        assertEq(_impl(VAULT_PROXY), newVaultImpl, "vault impl not updated");
        assertEq(_impl(MANAGER_PROXY), newManagerImpl, "manager impl not updated");
    }

    // ==================================================================
    // Operational roles are untouched by the batch
    // ==================================================================

    function test_handover_leavesOperationalRolesAlone() public {
        bool operatorBefore = manager.hasRole(OPERATOR_ROLE, safe);
        bool rebalancerBefore = yield.hasRole(REBALANCER_ROLE, safe);

        _executeHandover();

        assertEq(manager.hasRole(OPERATOR_ROLE, safe), operatorBefore, "OPERATOR changed");
        assertEq(yield.hasRole(REBALANCER_ROLE, safe), rebalancerBefore, "REBALANCER changed");
    }

    // ==================================================================
    // Governance is delayed on the real deployment
    // ==================================================================

    function test_afterHandover_governanceRequiresDelay() public {
        _executeHandover();

        uint256 newFee = before.fee == 1e17 ? 2e17 : 1e17;
        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, newFee);
        bytes32 salt = keccak256("fork-test-fee");

        vm.prank(safe);
        timelock.schedule(VAULT_PROXY, 0, data, bytes32(0), salt, MIN_DELAY);
        assertEq(vault.fee(), before.fee, "fee changed at schedule time");

        // One second early still reverts.
        vm.warp(block.timestamp + MIN_DELAY - 1);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(VAULT_PROXY, 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        timelock.execute(VAULT_PROXY, 0, data, bytes32(0), salt);

        assertEq(vault.fee(), newFee, "fee did not apply after the delay");
    }

    function test_afterHandover_safeCannotActDirectly() public {
        _executeHandover();

        vm.prank(safe);
        vm.expectRevert();
        vault.setFee(1e17);

        vm.prank(safe);
        vm.expectRevert();
        manager.setTreasury(address(0xdead));
    }

    function test_afterHandover_upgradeRequiresTimelock() public {
        _executeHandover();
        address another = address(new TownSqToken());

        vm.prank(safe);
        vm.expectRevert();
        vault.upgradeToAndCall(another, "");
    }

    // ==================================================================
    // The guardian carve-outs work on the real deployment
    // ==================================================================

    function test_afterHandover_guardianPausesInstantly() public {
        _executeHandover();

        uint256 t0 = block.timestamp;
        vm.prank(safe);
        vault.pause();

        assertTrue(vault.paused(), "guardian could not pause live vault");
        assertEq(block.timestamp, t0, "pause was not instant");
    }

    function test_afterHandover_guardianCannotUnpause() public {
        _executeHandover();

        vm.prank(safe);
        vault.pause();

        vm.prank(safe);
        vm.expectRevert();
        vault.unpause();

        assertTrue(vault.paused(), "guardian unpaused");
    }

    function test_afterHandover_guardianRevokesWhitelistInstantly() public {
        _executeHandover();

        // Authorise a destination through the timelock, then cut it off with no delay.
        address[] memory wallets = new address[](1);
        wallets[0] = address(0xBEEF);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        bytes memory data = abi.encodeWithSelector(Manager.setWhitelistedAddresses.selector, wallets, statuses);
        bytes32 salt = keccak256("fork-test-whitelist");

        vm.prank(safe);
        timelock.schedule(MANAGER_PROXY, 0, data, bytes32(0), salt, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(safe);
        timelock.execute(MANAGER_PROXY, 0, data, bytes32(0), salt);

        assertTrue(manager.whitelistedAddresses(address(0xBEEF)), "whitelist add failed");

        uint256 t0 = block.timestamp;
        vm.prank(safe);
        manager.removeWhitelistedAddresses(wallets);

        assertFalse(manager.whitelistedAddresses(address(0xBEEF)), "guardian could not revoke");
        assertEq(block.timestamp, t0, "revoke was not instant");
    }

    function test_afterHandover_randomAddressCannotPause() public {
        _executeHandover();

        vm.prank(address(0xBAD));
        vm.expectRevert(Errors.NotAuthorized.selector);
        vault.pause();
    }

    // ==================================================================
    // Existing whitelist entries survive
    // ==================================================================

    function test_upgrade_preservesWhitelistMapping() public {
        // Sample the live whitelist via its event history is out of scope here; instead
        // prove the mapping slot is untouched by writing through the OLD implementation,
        // upgrading, and reading back.
        address probe = address(0xC0FFEE);

        address[] memory wallets = new address[](1);
        wallets[0] = probe;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(safe);
        manager.setWhitelistedAddresses(wallets, statuses);
        assertTrue(manager.whitelistedAddresses(probe), "pre-upgrade write failed");

        _executeHandover();

        assertTrue(manager.whitelistedAddresses(probe), "whitelist entry lost across upgrade");
    }

    function _impl(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
