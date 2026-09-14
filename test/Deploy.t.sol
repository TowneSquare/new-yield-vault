// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "openzeppelin-contracts/governance/TimelockController.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";

/// @dev Stands in for a Safe. The deploy script requires the guardian to be a contract, so
/// an EOA cannot be passed by mistake; this just needs code at its address.
contract MockSafe {
    receive() external payable {}
}

/**
 * @title DeployScriptTest
 * @notice Runs script/Deploy.s.sol end to end and asserts the resulting role topology.
 *
 * Drives `deploy(pk, cfg)` rather than `run()`. `run()` reads configuration from the
 * environment, and `vm.setEnv` mutates the shared process environment, so env-driven tests
 * leak values into one another.
 *
 * The script carries its own `_verify` assertions, so this suite proves two things beyond
 * "it did not revert": that preflight rejects bad input before spending gas, and that the
 * deployed system actually behaves as timelocked afterwards.
 */
contract DeployScriptTest is Test {
    DeployScript script;
    MockERC20 asset;
    MockSafe safe;

    uint256 constant DEPLOYER_PK = 0xA11CE;
    address deployer;

    address executor = makeAddr("executor");
    address rebalancer = makeAddr("rebalancer");
    address treasury = makeAddr("treasury");

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        asset = new MockERC20("USDC", "USDC");
        safe = new MockSafe();
        script = new DeployScript();
    }

    /// @dev A valid configuration. Tests mutate one field to exercise a single guard.
    function _cfg() internal view returns (DeployScript.Config memory cfg) {
        cfg.deployer = deployer;
        cfg.safe = address(safe);
        cfg.executor = executor;
        cfg.rebalancer = rebalancer;
        cfg.asset = address(asset);
        cfg.treasury = treasury;
        cfg.maxRedeemCap = 0;
        cfg.minShares = 1e6;
        cfg.timelockDelay = 48 hours;
        cfg.exitFee = 1e17; // 0.1%
        cfg.name = "TownSquare USD";
        cfg.symbol = "townSqUSD";
    }

    function _deploy() internal {
        script.deploy(DEPLOYER_PK, _cfg());
    }

    // ==================================================================
    // Governance lands where intended
    // ==================================================================

    function test_deploy_putsGovernanceBehindTimelock() public {
        _deploy();

        TownSqToken vault = script.vault();
        Manager manager = script.manager();
        Yield yieldContract = script.yieldContract();
        TimelockController timelock = script.timelock();

        assertTrue(vault.hasRole(vault.ADMIN_ROLE(), address(timelock)), "vault ADMIN");
        assertTrue(vault.hasRole(0x00, address(timelock)), "vault DEFAULT_ADMIN");
        assertTrue(manager.hasRole(manager.ADMIN_ROLE(), address(timelock)), "manager ADMIN");
        assertTrue(yieldContract.hasRole(yieldContract.ADMIN_ROLE(), address(timelock)), "yield ADMIN");

        assertEq(timelock.getMinDelay(), 48 hours, "delay");
    }

    function test_deploy_leavesDeployerWithNothing() public {
        _deploy();

        TownSqToken vault = script.vault();
        Manager manager = script.manager();
        Yield yieldContract = script.yieldContract();

        assertFalse(vault.hasRole(vault.ADMIN_ROLE(), deployer), "vault ADMIN");
        assertFalse(vault.hasRole(0x00, deployer), "vault DEFAULT_ADMIN");
        assertFalse(manager.hasRole(manager.ADMIN_ROLE(), deployer), "manager ADMIN");
        assertFalse(manager.hasRole(0x00, deployer), "manager DEFAULT_ADMIN");
        assertFalse(yieldContract.hasRole(yieldContract.ADMIN_ROLE(), deployer), "yield ADMIN");
        assertFalse(yieldContract.hasRole(0x00, deployer), "yield DEFAULT_ADMIN");
    }

    function test_deploy_givesSafeGuardianOnly() public {
        _deploy();

        TownSqToken vault = script.vault();
        Manager manager = script.manager();

        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), address(safe)), "vault GUARDIAN");
        assertTrue(manager.hasRole(manager.GUARDIAN_ROLE(), address(safe)), "manager GUARDIAN");

        assertFalse(vault.hasRole(vault.ADMIN_ROLE(), address(safe)), "safe has vault ADMIN");
        assertFalse(vault.hasRole(0x00, address(safe)), "safe has vault DEFAULT_ADMIN");
        assertFalse(manager.hasRole(manager.ADMIN_ROLE(), address(safe)), "safe has manager ADMIN");
    }

    function test_deploy_setsOperationalRoles() public {
        _deploy();

        assertTrue(script.manager().hasRole(script.manager().OPERATOR_ROLE(), executor), "OPERATOR");
        assertTrue(script.yieldContract().hasRole(keccak256("REBALANCER_ROLE"), rebalancer), "REBALANCER");
    }

    function test_deploy_wiresCrossReferences() public {
        _deploy();

        assertEq(script.vault().manager(), address(script.manager()), "vault -> manager");
        assertEq(script.manager().townSqToken(), address(script.vault()), "manager -> vault");
        assertEq(script.manager().yield(), address(script.yieldContract()), "manager -> yield");
        assertEq(script.manager().treasury(), treasury, "treasury");
    }

    function test_deploy_appliesParameters() public {
        _deploy();

        assertEq(script.vault().fee(), 1e17, "exit fee");
        assertEq(script.vault().cooldownPeriod(), 1 days, "cooldown");
        assertEq(script.vault().vestingPeriod(), 7 days, "vesting");
        assertEq(script.manager().minSharesInVaultToken(address(script.vault())), 1e6, "minShares");
    }

    function test_deploy_leavesNoTimelockAdmin() public {
        _deploy();
        TimelockController timelock = script.timelock();

        assertFalse(timelock.hasRole(0x00, deployer), "deployer administers timelock");
        assertFalse(timelock.hasRole(0x00, address(safe)), "safe administers timelock");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(safe)), "safe cannot propose");
    }

    // ==================================================================
    // The deployed system really is timelocked
    // ==================================================================

    function test_deploy_governanceActionRequiresDelay() public {
        _deploy();
        TownSqToken vault = script.vault();
        TimelockController timelock = script.timelock();

        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, 5e17);

        vm.prank(address(safe));
        timelock.schedule(address(vault), 0, data, bytes32(0), bytes32("salt"), 48 hours);
        assertEq(vault.fee(), 1e17, "fee moved at schedule time");

        vm.warp(block.timestamp + 48 hours);
        vm.prank(address(safe));
        timelock.execute(address(vault), 0, data, bytes32(0), bytes32("salt"));

        assertEq(vault.fee(), 5e17, "fee did not apply after delay");
    }

    function test_deploy_guardianCanPauseImmediately() public {
        _deploy();

        // Cache the vault first: `script.vault()` is its own call and would consume the
        // prank, leaving `pause()` to be sent by this test contract instead of the safe.
        TownSqToken vault = script.vault();

        vm.prank(address(safe));
        vault.pause();

        assertTrue(vault.paused(), "guardian could not pause");
    }

    // ==================================================================
    // Preflight rejects bad input before spending gas
    // ==================================================================

    function test_RevertWhen_safeIsAnEOA() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.safe = makeAddr("eoa");

        vm.expectRevert(bytes("SAFE_ADDRESS has no code - expected a multisig"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_safeIsTheDeployer() public {
        // Give the deployer code so it clears the contract check and reaches the next guard.
        vm.etch(deployer, hex"00");

        DeployScript.Config memory cfg = _cfg();
        cfg.safe = deployer;

        vm.expectRevert(bytes("safe must not be the deployer"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_executorIsTheDeployer() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.executor = deployer;

        vm.expectRevert(bytes("executor must not be the deployer"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_assetHasNoCode() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.asset = makeAddr("notAToken");

        vm.expectRevert(bytes("ASSET_ADDRESS has no code"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_minSharesIsZero() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.minShares = 0;

        vm.expectRevert(bytes("MIN_SHARES must be non-zero"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_treasuryUnset() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.treasury = address(0);

        vm.expectRevert(bytes("TREASURY_ADDRESS unset"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_timelockDelayIsZero() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.timelockDelay = 0;

        vm.expectRevert(bytes("TIMELOCK_DELAY must be non-zero"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    // ==================================================================
    // Sharing one timelock across vault deployments
    // ==================================================================

    /// @dev Deploys a first vault and returns the timelock it created.
    function _deployFirstVault() internal returns (TimelockController) {
        DeployScript first = new DeployScript();
        first.deploy(DEPLOYER_PK, _cfg());
        return first.timelock();
    }

    function test_reuse_secondVaultSharesTheSameTimelock() public {
        TimelockController shared = _deployFirstVault();

        DeployScript.Config memory cfg = _cfg();
        cfg.existingTimelock = address(shared);
        cfg.name = "TownSquare BTC";
        cfg.symbol = "townSqBTC";

        script.deploy(DEPLOYER_PK, cfg);

        assertEq(address(script.timelock()), address(shared), "did not reuse the timelock");
        assertTrue(script.reusedTimelock(), "reuse flag not set");

        // The shared timelock governs the second vault too.
        assertTrue(script.vault().hasRole(script.vault().ADMIN_ROLE(), address(shared)), "vault ADMIN");
        assertTrue(script.manager().hasRole(0x00, address(shared)), "manager DEFAULT_ADMIN");
    }

    function test_reuse_governsBothVaultsIndependently() public {
        TimelockController shared = _deployFirstVault();

        DeployScript.Config memory cfg = _cfg();
        cfg.existingTimelock = address(shared);
        script.deploy(DEPLOYER_PK, cfg);

        TownSqToken second = script.vault();

        // A proposal against the second vault runs through the shared timelock normally.
        bytes memory data = abi.encodeWithSelector(TownSqToken.setFee.selector, 3e17);

        vm.prank(address(safe));
        shared.schedule(address(second), 0, data, bytes32(0), bytes32("v2-fee"), 48 hours);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(address(safe));
        shared.execute(address(second), 0, data, bytes32(0), bytes32("v2-fee"));

        assertEq(second.fee(), 3e17, "second vault fee did not apply");
    }

    function test_reuse_freshDeployDoesNotSetReuseFlag() public {
        _deploy();
        assertFalse(script.reusedTimelock(), "fresh deploy marked as reused");
    }

    function test_reuse_adoptsExistingDelayOverRequested() public {
        // A timelock with a 7-day floor, not the 48h this config asks for.
        address[] memory signers = new address[](1);
        signers[0] = address(safe);
        TimelockController sevenDay = new TimelockController(7 days, signers, signers, address(0));

        DeployScript.Config memory cfg = _cfg();
        cfg.existingTimelock = address(sevenDay);
        cfg.timelockDelay = 48 hours; // ignored

        script.deploy(DEPLOYER_PK, cfg);

        assertEq(script.timelock().getMinDelay(), 7 days, "existing delay not adopted");
    }

    function test_RevertWhen_reusingTimelockWithNoCode() public {
        DeployScript.Config memory cfg = _cfg();
        cfg.existingTimelock = makeAddr("notATimelock");

        vm.expectRevert(bytes("TIMELOCK_ADDRESS has no code"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_safeCannotProposeToReusedTimelock() public {
        // A timelock whose proposer is somebody else entirely.
        address[] memory others = new address[](1);
        others[0] = makeAddr("otherSafe");
        TimelockController foreign = new TimelockController(48 hours, others, others, address(0));

        DeployScript.Config memory cfg = _cfg();
        cfg.existingTimelock = address(foreign);

        vm.expectRevert(bytes("safe cannot propose to this timelock"));
        script.deploy(DEPLOYER_PK, cfg);
    }

    function test_RevertWhen_safeCannotExecuteOnReusedTimelock() public {
        // Proposer but not executor.
        address[] memory proposers = new address[](1);
        proposers[0] = address(safe);
        address[] memory executors = new address[](1);
        executors[0] = makeAddr("otherExecutor");
        TimelockController proposerOnly = new TimelockController(48 hours, proposers, executors, address(0));

        DeployScript.Config memory cfg = _cfg();
        cfg.existingTimelock = address(proposerOnly);

        vm.expectRevert(bytes("safe cannot execute on this timelock"));
        script.deploy(DEPLOYER_PK, cfg);
    }
}
