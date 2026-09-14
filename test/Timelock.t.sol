// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {Errors} from "../src/Errors.sol";

/**
 * @title TimelockTest
 * @notice Characterises governance once DEFAULT_ADMIN/ADMIN sit behind a TimelockController
 * and GUARDIAN_ROLE holds the emergency carve-outs.
 *
 * The properties being pinned:
 *   1. Every governance action takes MIN_DELAY. No exceptions, no bypass.
 *   2. The guardian can pause and revoke whitelist entries instantly.
 *   3. The guardian can do NOTHING else -- it cannot unpause, set fees, add whitelist
 *      entries, upgrade, or grant itself anything.
 *   4. Operational roles are unaffected by the timelock.
 */
contract TimelockTest is Test {
    uint256 constant MIN_DELAY = 48 hours;

    MockERC20 asset;
    TownSqToken vault;
    Manager manager;
    Yield yield;
    TimelockController timelock;

    address deployer = makeAddr("deployer");
    address safe = makeAddr("safe");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");
    address rebalancer = makeAddr("rebalancer");
    address operator = makeAddr("operator");
    address attacker = makeAddr("attacker");
    address destination = makeAddr("destination");

    uint256 constant COOLDOWN = 24 hours;
    uint256 constant VESTING = 7 days;

    function setUp() public {
        vm.startPrank(deployer);

        asset = new MockERC20("USDC", "USDC");

        TownSqToken vaultImpl = new TownSqToken();
        Manager managerImpl = new Manager();
        Yield yieldImpl = new Yield();

        yield = Yield(
            address(
                new townSqProxy(
                    address(yieldImpl), abi.encodeWithSelector(Yield.initialize.selector, deployer, rebalancer)
                )
            )
        );
        manager = Manager(
            address(
                new townSqProxy(
                    address(managerImpl),
                    abi.encodeWithSelector(Manager.initialize.selector, deployer, address(yield), operator)
                )
            )
        );
        vault = TownSqToken(
            address(
                new townSqProxy(
                    address(vaultImpl),
                    abi.encodeWithSelector(
                        TownSqToken.initialize.selector,
                        "townSqUSD",
                        "townSqUSD",
                        IERC20(asset),
                        deployer,
                        address(manager),
                        COOLDOWN,
                        VESTING
                    )
                )
            )
        );

        manager.setTreasury(treasury);
        manager.setManagerAndYield(address(yield), address(vault));
        manager.setMinSharesInVaultToken(address(vault), 1e6);
        manager.setMaxRedeemCap(address(vault), type(uint256).max);
        yield.setManager(address(manager));

        // --- deploy the timelock exactly as DeployTimelock.s.sol does ---
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // --- handover, in the order TimelockRoleChange.s.sol emits ---
        vault.grantRole(vault.GUARDIAN_ROLE(), safe);
        manager.grantRole(manager.GUARDIAN_ROLE(), safe);

        vault.grantRole(vault.ADMIN_ROLE(), address(timelock));
        vault.grantRole(0x00, address(timelock));
        manager.grantRole(manager.ADMIN_ROLE(), address(timelock));
        manager.grantRole(0x00, address(timelock));
        yield.grantRole(yield.ADMIN_ROLE(), address(timelock));
        yield.grantRole(0x00, address(timelock));

        vault.revokeRole(vault.ADMIN_ROLE(), deployer);
        vault.revokeRole(0x00, deployer);
        manager.revokeRole(manager.ADMIN_ROLE(), deployer);
        manager.revokeRole(0x00, deployer);
        yield.revokeRole(yield.ADMIN_ROLE(), deployer);
        yield.revokeRole(0x00, deployer);

        vm.stopPrank();

        asset.mint(user, 1_000_000e6);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _schedule(address target, bytes memory data) internal returns (bytes32 id) {
        vm.prank(safe);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), MIN_DELAY);
        id = timelock.hashOperation(target, 0, data, bytes32(0), bytes32(0));
    }

    function _execute(address target, bytes memory data) internal {
        vm.prank(safe);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function _scheduleAndExecute(address target, bytes memory data) internal {
        _schedule(target, data);
        vm.warp(block.timestamp + MIN_DELAY);
        _execute(target, data);
    }

    // ==================================================================
    // 1. Governance is delayed
    // ==================================================================

    function test_setFee_throughTimelock_succeedsAfterDelay() public {
        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, 5e17);

        _schedule(address(vault), data);
        assertEq(vault.fee(), 0, "fee must not change at schedule time");

        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(vault), data);

        assertEq(vault.fee(), 5e17, "fee should apply after the delay");
    }

    function test_RevertWhen_executingBeforeDelayElapses() public {
        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, 5e17);
        _schedule(address(vault), data);

        vm.warp(block.timestamp + MIN_DELAY - 1);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));

        assertEq(vault.fee(), 0, "fee changed before the delay elapsed");
    }

    function test_RevertWhen_safeCallsAdminFunctionDirectly() public {
        vm.prank(safe);
        vm.expectRevert();
        vault.setFee(5e17);
    }

    function test_upgrade_requiresTimelock() public {
        TownSqToken newImpl = new TownSqToken();

        vm.prank(safe);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");

        _scheduleAndExecute(
            address(vault), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""))
        );
        // Reaching here means the upgrade succeeded only via the timelock.
    }

    function test_whitelistAddition_isDelayed() public {
        address[] memory wallets = new address[](1);
        wallets[0] = destination;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        bytes memory data = abi.encodeWithSelector(Manager.setWhitelistedAddresses.selector, wallets, statuses);

        _schedule(address(manager), data);
        assertFalse(manager.whitelistedAddresses(destination), "whitelisted at schedule time");

        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(manager), data);

        assertTrue(manager.whitelistedAddresses(destination), "not whitelisted after delay");
    }

    function test_cancel_stopsAPendingProposal() public {
        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, 5e17);
        bytes32 id = _schedule(address(vault), data);

        vm.prank(safe);
        timelock.cancel(id);

        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));

        assertEq(vault.fee(), 0, "cancelled proposal still applied");
    }

    // ==================================================================
    // 2. The guardian carve-outs work instantly
    // ==================================================================

    function test_guardian_canPauseImmediately() public {
        vm.prank(safe);
        vault.pause();
        assertTrue(vault.paused(), "guardian could not pause");
    }

    function test_guardian_canRemoveWhitelistImmediately() public {
        address[] memory wallets = new address[](1);
        wallets[0] = destination;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        _scheduleAndExecute(
            address(manager), abi.encodeWithSelector(Manager.setWhitelistedAddresses.selector, wallets, statuses)
        );
        assertTrue(manager.whitelistedAddresses(destination));

        // Same block, no delay.
        vm.prank(safe);
        manager.removeWhitelistedAddresses(wallets);

        assertFalse(manager.whitelistedAddresses(destination), "guardian could not revoke");
    }

    /// @notice The whole point of the carve-out: an exploit is halted in the same block it
    /// is noticed, not 48 hours later.
    function test_guardian_haltsExploitWithoutWaitingForTimelock() public {
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1000e6, user);
        vm.stopPrank();

        uint256 t0 = block.timestamp;

        vm.prank(safe);
        vault.pause();

        assertEq(block.timestamp, t0, "pause took time");
        assertTrue(vault.paused());

        vm.startPrank(user);
        vm.expectRevert();
        vault.deposit(1e6, user);
        vm.stopPrank();
    }

    // ==================================================================
    // 3. The guardian can do nothing else
    // ==================================================================

    function test_RevertWhen_guardianTriesToUnpause() public {
        vm.prank(safe);
        vault.pause();

        vm.prank(safe);
        vm.expectRevert();
        vault.unpause();

        assertTrue(vault.paused(), "guardian managed to unpause");
    }

    function test_unpause_requiresTimelock() public {
        vm.prank(safe);
        vault.pause();

        _scheduleAndExecute(address(vault), abi.encodeWithSelector(TownSqToken.unpause.selector));

        assertFalse(vault.paused(), "timelock could not unpause");
    }

    function test_RevertWhen_guardianTriesToAddWhitelistEntry() public {
        address[] memory wallets = new address[](1);
        wallets[0] = attacker;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(safe);
        vm.expectRevert();
        manager.setWhitelistedAddresses(wallets, statuses);

        assertFalse(manager.whitelistedAddresses(attacker), "guardian whitelisted an address");
    }

    function test_RevertWhen_guardianTriesToSetFee() public {
        vm.prank(safe);
        vm.expectRevert();
        vault.setFee(1e18);
    }

    function test_RevertWhen_guardianTriesToRecoverAssets() public {
        vm.prank(safe);
        vm.expectRevert();
        vault.emergencyRecover(address(asset), 1, safe);
    }

    function test_RevertWhen_guardianTriesToGrantItselfAdmin() public {
        // Resolve the role BEFORE expectRevert: `vault.ADMIN_ROLE()` is its own staticcall,
        // and inlining it would consume both the prank and the expectRevert.
        bytes32 adminRole = vault.ADMIN_ROLE();

        vm.prank(safe);
        vm.expectRevert();
        vault.grantRole(adminRole, safe);

        assertFalse(vault.hasRole(adminRole, safe), "guardian granted itself ADMIN");
    }

    function test_RevertWhen_guardianTriesToGrantItselfDefaultAdmin() public {
        vm.prank(safe);
        vm.expectRevert();
        vault.grantRole(0x00, safe);

        assertFalse(vault.hasRole(0x00, safe), "guardian granted itself DEFAULT_ADMIN");
    }

    function test_RevertWhen_randomAddressPauses() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.NotAuthorized.selector);
        vault.pause();
    }

    function test_RevertWhen_randomAddressRemovesWhitelist() public {
        address[] memory wallets = new address[](1);
        wallets[0] = destination;

        vm.prank(attacker);
        vm.expectRevert(Errors.NotAuthorized.selector);
        manager.removeWhitelistedAddresses(wallets);
    }

    // ==================================================================
    // 4. Operational roles are untouched
    // ==================================================================

    function test_operator_stillWorksWithoutDelay() public {
        address[] memory wallets = new address[](1);
        wallets[0] = address(asset);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        _scheduleAndExecute(
            address(manager), abi.encodeWithSelector(Manager.setWhitelistedAddresses.selector, wallets, statuses)
        );

        asset.mint(address(manager), 1000e6);

        address[] memory targets = new address[](1);
        targets[0] = address(asset);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", destination, 100e6);

        vm.prank(operator);
        manager.execute(targets, data);

        assertEq(asset.balanceOf(destination), 100e6, "operator blocked by timelock");
    }

    function test_rebalancer_stillWorksWithoutDelay() public {
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, user);
        vm.stopPrank();

        uint256 before = vault.virtualAssets();

        vm.prank(rebalancer);
        yield.distributeYield(10e6, 0, 1, true);

        assertGt(vault.virtualAssets(), before, "rebalancer blocked by timelock");
    }

    // ==================================================================
    // 5. The Safe really has given up governance
    // ==================================================================

    function test_safeHoldsNoGovernanceRoles() public view {
        assertFalse(vault.hasRole(vault.ADMIN_ROLE(), safe), "safe still vault ADMIN");
        assertFalse(vault.hasRole(0x00, safe), "safe still vault DEFAULT_ADMIN");
        assertFalse(manager.hasRole(manager.ADMIN_ROLE(), safe), "safe still manager ADMIN");
        assertFalse(manager.hasRole(0x00, safe), "safe still manager DEFAULT_ADMIN");
        assertFalse(yield.hasRole(yield.ADMIN_ROLE(), safe), "safe still yield ADMIN");
        assertFalse(yield.hasRole(0x00, safe), "safe still yield DEFAULT_ADMIN");

        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), safe), "safe lost GUARDIAN");
        assertTrue(manager.hasRole(manager.GUARDIAN_ROLE(), safe), "safe lost GUARDIAN");
    }

    function test_timelockHoldsGovernance() public view {
        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), address(timelock)));
        assertTrue(vault.hasRole(0x00, address(timelock)));
        assertTrue(manager.hasRole(manager.ADMIN_ROLE(), address(timelock)));
        assertTrue(yield.hasRole(yield.ADMIN_ROLE(), address(timelock)));
    }

    function test_deployerRetainsNothing() public view {
        assertFalse(vault.hasRole(vault.ADMIN_ROLE(), deployer));
        assertFalse(vault.hasRole(0x00, deployer));
        assertFalse(manager.hasRole(0x00, deployer));
        assertFalse(yield.hasRole(0x00, deployer));
    }

    function test_timelockHasNoStandingAdmin() public view {
        assertFalse(
            timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "deployer can still administer the timelock"
        );
    }

    // ==================================================================
    // 6. Fuzz: no delay shorter than MIN_DELAY ever executes
    // ==================================================================

    function testFuzz_executionAlwaysWaitsMinDelay(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, MIN_DELAY - 1);

        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, 5e17);
        _schedule(address(vault), data);

        vm.warp(block.timestamp + elapsed);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32(0));

        assertEq(vault.fee(), 0);
    }
}
