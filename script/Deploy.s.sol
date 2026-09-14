// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "openzeppelin-contracts/governance/TimelockController.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";

/**
 * @title DeployScript
 * @notice Full protocol deployment, timelocked from genesis.
 *
 *   forge script script/Deploy.s.sol --rpc-url <chain> --broadcast
 *
 * Governance lands behind a TimelockController immediately rather than being handed over
 * later, so there is never a window in which a single key can change the protocol without
 * delay. The deployer holds ADMIN only for the length of this script -- long enough to wire
 * cross-references and set parameters -- and is stripped before it returns.
 *
 * Roles at the end:
 *   DEFAULT_ADMIN / ADMIN  -> TimelockController (48h delay)
 *   GUARDIAN               -> Safe (instant pause + whitelist removal only)
 *   OPERATOR               -> executor        (operational, no delay)
 *   REBALANCER             -> rebalancer      (operational, no delay)
 *   deployer               -> nothing
 *
 * Required env:
 *   DEPLOYER_PK, SAFE_ADDRESS, EXECUTOR_ADDRESS, REBALANCER_ADDRESS,
 *   ASSET_ADDRESS, TREASURY_ADDRESS, MAX_REDEEM_CAP, MIN_SHARES
 * Optional env:
 *   TIMELOCK_DELAY (default 48h), VAULT_NAME, VAULT_SYMBOL, EXIT_FEE
 */
contract DeployScript is Script {
    uint256 constant DEFAULT_TIMELOCK_DELAY = 48 hours;
    uint256 constant VESTING_PERIOD = 7 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    struct Config {
        address deployer;
        address safe;
        address executor;
        address rebalancer;
        address asset;
        address treasury;
        uint256 maxRedeemCap;
        uint256 minShares;
        uint256 timelockDelay;
        uint256 exitFee;
        string name;
        string symbol;
        /// @dev Set to reuse an existing TimelockController across vault deployments.
        /// address(0) deploys a fresh one. See _setUpTimelock for the trade-off.
        address existingTimelock;
    }

    // Public so a caller -- a test, or another script importing this one -- can read the
    // deployed addresses after run() without re-parsing console output.
    TimelockController public timelock;
    TownSqToken public vault;
    Manager public manager;
    Yield public yieldContract;

    address public vaultImpl;
    address public managerImpl;
    address public yieldImpl;

    /// @dev True when an existing timelock was reused rather than a new one deployed.
    bool public reusedTimelock;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        deploy(deployerPk, _loadConfig(vm.addr(deployerPk)));
    }

    /**
     * @notice The deployment itself, with configuration supplied explicitly.
     * @dev Separated from `run()` so tests can drive it deterministically. Going through
     * env vars instead would be flaky: `vm.setEnv` mutates the shared process environment,
     * so one test's values leak into another's.
     */
    function deploy(uint256 deployerPk, Config memory cfg) public {
        _preflight(cfg);

        // Broadcast with the key itself, not the address: the address overload requires a
        // signer to be supplied on the command line (--private-key / --account / --ledger).
        vm.startBroadcast(deployerPk);

        _setUpTimelock(cfg);
        _deployImplementations();
        _deployProxies(cfg);
        _configure(cfg);
        _handOverGovernance(cfg);

        vm.stopBroadcast();

        _verify(cfg);
        _report(cfg);
    }

    // ------------------------------------------------------------------
    // config
    // ------------------------------------------------------------------

    function _loadConfig(address deployer) internal view virtual returns (Config memory cfg) {
        cfg.deployer = deployer;
        cfg.safe = vm.envAddress("SAFE_ADDRESS");
        cfg.executor = vm.envAddress("EXECUTOR_ADDRESS");
        cfg.rebalancer = vm.envAddress("REBALANCER_ADDRESS");
        cfg.asset = vm.envAddress("ASSET_ADDRESS");
        cfg.treasury = vm.envAddress("TREASURY_ADDRESS");
        cfg.maxRedeemCap = vm.envUint("MAX_REDEEM_CAP");
        cfg.minShares = vm.envUint("MIN_SHARES");
        cfg.timelockDelay = vm.envOr("TIMELOCK_DELAY", DEFAULT_TIMELOCK_DELAY);
        cfg.exitFee = vm.envOr("EXIT_FEE", uint256(0));

        // Named explicitly rather than hardcoded: the same script deploys vaults over
        // different assets, and a stale literal here mislabels the token permanently.
        cfg.name = vm.envOr("VAULT_NAME", string("TownSquare USD"));
        cfg.symbol = vm.envOr("VAULT_SYMBOL", string("townSqUSD"));

        // Unset deploys a fresh timelock. Set it to govern this vault with an existing one.
        cfg.existingTimelock = vm.envOr("TIMELOCK_ADDRESS", address(0));
    }

    /// @dev Fail before spending gas, not halfway through a deployment.
    function _preflight(Config memory cfg) internal view {
        require(cfg.safe != address(0), "SAFE_ADDRESS unset");
        require(cfg.executor != address(0), "EXECUTOR_ADDRESS unset");
        require(cfg.rebalancer != address(0), "REBALANCER_ADDRESS unset");
        require(cfg.treasury != address(0), "TREASURY_ADDRESS unset");
        require(cfg.asset.code.length > 0, "ASSET_ADDRESS has no code");
        require(cfg.minShares > 0, "MIN_SHARES must be non-zero");
        require(cfg.timelockDelay > 0, "TIMELOCK_DELAY must be non-zero");

        // A Safe is a contract. An EOA here would mean the guardian and the timelock's sole
        // proposer is a single key, which defeats the point of both.
        require(cfg.safe.code.length > 0, "SAFE_ADDRESS has no code - expected a multisig");

        require(cfg.safe != cfg.deployer, "safe must not be the deployer");
        require(cfg.executor != cfg.deployer, "executor must not be the deployer");
    }

    // ------------------------------------------------------------------
    // deployment
    // ------------------------------------------------------------------

    /**
     * @dev Reuse an existing TimelockController, or deploy a fresh one.
     *
     * A TimelockController holds no vault-specific state, so one instance can govern any
     * number of vaults. Operation ids hash the target address, so proposals for different
     * vaults never collide.
     *
     * Share it when the vaults are governed by the same signers at the same risk tier: one
     * contract to verify, one delay to audit, one address for depositors to watch.
     *
     * Do NOT share it when either the signer set or the risk tier differs. `minDelay` is
     * global -- a riskier vault cannot be given a higher floor, only a voluntarily longer
     * delay per proposal that a later proposer can decline to repeat -- and CANCELLER_ROLE
     * on a shared timelock can cancel any vault's pending proposals.
     */
    function _setUpTimelock(Config memory cfg) internal {
        if (cfg.existingTimelock != address(0)) {
            timelock = TimelockController(payable(cfg.existingTimelock));
            reusedTimelock = true;

            require(cfg.existingTimelock.code.length > 0, "TIMELOCK_ADDRESS has no code");

            // Reusing a timelock the Safe cannot drive would produce a vault nobody can
            // govern -- and, because the deployer renounces below, nobody could fix it.
            require(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.safe), "safe cannot propose to this timelock");
            require(timelock.hasRole(timelock.EXECUTOR_ROLE(), cfg.safe), "safe cannot execute on this timelock");
            require(timelock.getMinDelay() > 0, "existing timelock has zero delay");

            // The existing instance's delay governs. Adopt it so the post-deploy assertion
            // checks reality rather than a requested value that was never applied.
            if (timelock.getMinDelay() != cfg.timelockDelay) {
                console.log("NOTE: requested delay ignored; existing timelock enforces:", timelock.getMinDelay());
            }
            cfg.timelockDelay = timelock.getMinDelay();

            console.log("TimelockController      : (reused)", address(timelock));
            return;
        }

        address[] memory proposers = new address[](1);
        proposers[0] = cfg.safe;

        // Same address executes. address(0) would make execution permissionless, letting a
        // third party time a matured proposal into a moment of their choosing.
        address[] memory executors = new address[](1);
        executors[0] = cfg.safe;

        // admin == address(0): no separate timelock administrator. Any such address would be
        // a standing bypass of the delay this contract exists to enforce.
        timelock = new TimelockController(cfg.timelockDelay, proposers, executors, address(0));
        console.log("TimelockController      :", address(timelock));
    }

    function _deployImplementations() internal {
        vaultImpl = address(new TownSqToken());
        managerImpl = address(new Manager());
        yieldImpl = address(new Yield());

        console.log("TownSqToken impl       :", vaultImpl);
        console.log("Manager impl           :", managerImpl);
        console.log("Yield impl             :", yieldImpl);
    }

    function _deployProxies(Config memory cfg) internal {
        // All three initialise with the DEPLOYER as admin, not the final holder. The deployer
        // needs ADMIN to wire cross-references below; governance is handed to the timelock in
        // one place at the end, so there is a single point to audit rather than three.
        yieldContract = Yield(
            address(
                new townSqProxy(
                    yieldImpl, abi.encodeWithSelector(Yield.initialize.selector, cfg.deployer, cfg.rebalancer)
                )
            )
        );

        manager = Manager(
            address(
                new townSqProxy(
                    managerImpl,
                    abi.encodeWithSelector(
                        Manager.initialize.selector, cfg.deployer, address(yieldContract), cfg.executor
                    )
                )
            )
        );

        vault = TownSqToken(
            address(
                new townSqProxy(
                    vaultImpl,
                    abi.encodeWithSelector(
                        TownSqToken.initialize.selector,
                        cfg.name,
                        cfg.symbol,
                        IERC20(cfg.asset),
                        cfg.deployer,
                        address(manager),
                        COOLDOWN_PERIOD,
                        VESTING_PERIOD
                    )
                )
            )
        );

        console.log("Yield proxy            :", address(yieldContract));
        console.log("Manager proxy          :", address(manager));
        console.log("TownSqToken proxy      :", address(vault));
    }

    function _configure(Config memory cfg) internal {
        yieldContract.setManager(address(manager));

        manager.setTreasury(cfg.treasury);
        manager.setManagerAndYield(address(yieldContract), address(vault));
        manager.setMinSharesInVaultToken(address(vault), cfg.minShares);
        manager.setMaxRedeemCap(address(vault), cfg.maxRedeemCap);

        // Set here rather than leaving it to a post-deploy transaction: once governance is
        // timelocked, the first fee change costs a 48h proposal.
        if (cfg.exitFee > 0) vault.setFee(cfg.exitFee);
    }

    // ------------------------------------------------------------------
    // governance handover
    // ------------------------------------------------------------------

    function _handOverGovernance(Config memory cfg) internal {
        bytes32 DEFAULT_ADMIN = 0x00;

        // Guardian BEFORE the revokes. Ordering matters here for the same reason it does in
        // TimelockRoleChange.s.sol: stripping ADMIN first would leave a window in which
        // nothing can pause the vault.
        vault.grantRole(vault.GUARDIAN_ROLE(), cfg.safe);
        manager.grantRole(manager.GUARDIAN_ROLE(), cfg.safe);

        vault.grantRole(vault.ADMIN_ROLE(), address(timelock));
        vault.grantRole(DEFAULT_ADMIN, address(timelock));
        manager.grantRole(manager.ADMIN_ROLE(), address(timelock));
        manager.grantRole(DEFAULT_ADMIN, address(timelock));
        yieldContract.grantRole(yieldContract.ADMIN_ROLE(), address(timelock));
        yieldContract.grantRole(DEFAULT_ADMIN, address(timelock));

        // ADMIN before DEFAULT_ADMIN: DEFAULT_ADMIN is what authorises these revokes, so it
        // goes last or the script cuts its own feet off mid-transaction.
        vault.revokeRole(vault.ADMIN_ROLE(), cfg.deployer);
        vault.revokeRole(DEFAULT_ADMIN, cfg.deployer);
        manager.revokeRole(manager.ADMIN_ROLE(), cfg.deployer);
        manager.revokeRole(DEFAULT_ADMIN, cfg.deployer);
        yieldContract.revokeRole(yieldContract.ADMIN_ROLE(), cfg.deployer);
        yieldContract.revokeRole(DEFAULT_ADMIN, cfg.deployer);
    }

    // ------------------------------------------------------------------
    // post-deploy assertions
    // ------------------------------------------------------------------

    /// @dev Runs outside the broadcast. A failure here reverts the script before the
    /// transactions are submitted, rather than leaving a misconfigured live deployment.
    function _verify(Config memory cfg) internal view {
        bytes32 DEFAULT_ADMIN = 0x00;

        // Timelock holds governance.
        require(vault.hasRole(vault.ADMIN_ROLE(), address(timelock)), "vault ADMIN not timelock");
        require(vault.hasRole(DEFAULT_ADMIN, address(timelock)), "vault DEFAULT_ADMIN not timelock");
        require(manager.hasRole(manager.ADMIN_ROLE(), address(timelock)), "manager ADMIN not timelock");
        require(manager.hasRole(DEFAULT_ADMIN, address(timelock)), "manager DEFAULT_ADMIN not timelock");
        require(yieldContract.hasRole(yieldContract.ADMIN_ROLE(), address(timelock)), "yield ADMIN not timelock");
        require(yieldContract.hasRole(DEFAULT_ADMIN, address(timelock)), "yield DEFAULT_ADMIN not timelock");

        // Deployer holds nothing. This is the check that matters most -- a deployer key
        // retaining DEFAULT_ADMIN is a silent single point of failure.
        require(!vault.hasRole(vault.ADMIN_ROLE(), cfg.deployer), "deployer retains vault ADMIN");
        require(!vault.hasRole(DEFAULT_ADMIN, cfg.deployer), "deployer retains vault DEFAULT_ADMIN");
        require(!manager.hasRole(manager.ADMIN_ROLE(), cfg.deployer), "deployer retains manager ADMIN");
        require(!manager.hasRole(DEFAULT_ADMIN, cfg.deployer), "deployer retains manager DEFAULT_ADMIN");
        require(!yieldContract.hasRole(yieldContract.ADMIN_ROLE(), cfg.deployer), "deployer retains yield ADMIN");
        require(!yieldContract.hasRole(DEFAULT_ADMIN, cfg.deployer), "deployer retains yield DEFAULT_ADMIN");

        // Safe holds the emergency carve-out and nothing more.
        require(vault.hasRole(vault.GUARDIAN_ROLE(), cfg.safe), "safe lacks vault GUARDIAN");
        require(manager.hasRole(manager.GUARDIAN_ROLE(), cfg.safe), "safe lacks manager GUARDIAN");
        require(!vault.hasRole(vault.ADMIN_ROLE(), cfg.safe), "safe holds vault ADMIN");
        require(!manager.hasRole(DEFAULT_ADMIN, cfg.safe), "safe holds manager DEFAULT_ADMIN");

        // Operational roles landed where intended.
        require(manager.hasRole(manager.OPERATOR_ROLE(), cfg.executor), "executor lacks OPERATOR");
        require(yieldContract.hasRole(keccak256("REBALANCER_ROLE"), cfg.rebalancer), "rebalancer lacks REBALANCER_ROLE");

        // No standing bypass of the delay. This cannot prove that *nobody* holds
        // DEFAULT_ADMIN on the timelock -- AccessControl is not enumerable -- only that the
        // two addresses in play here do not. When reusing a timelock, audit its
        // RoleGranted history separately.
        require(!timelock.hasRole(DEFAULT_ADMIN, cfg.deployer), "deployer administers the timelock");
        require(!timelock.hasRole(DEFAULT_ADMIN, cfg.safe), "safe administers the timelock");
        require(timelock.getMinDelay() == cfg.timelockDelay, "timelock delay mismatch");

        // The Safe must be able to drive whichever timelock now governs this vault.
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), cfg.safe), "safe cannot propose");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), cfg.safe), "safe cannot execute");

        // Cross-references resolve both ways.
        require(vault.manager() == address(manager), "vault -> manager broken");
        require(manager.townSqToken() == address(vault), "manager -> vault broken");
        require(manager.yield() == address(yieldContract), "manager -> yield broken");
        require(manager.treasury() == cfg.treasury, "treasury not set");
    }

    function _report(Config memory cfg) internal view {
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Proxies (interact with these):");
        console.log("  TownSqToken :", address(vault));
        console.log("  Manager     :", address(manager));
        console.log("  Yield       :", address(yieldContract));
        console.log("  Timelock    :", address(timelock));
        console.log("");
        console.log("Implementations (verify these):");
        console.log("  TownSqToken :", vaultImpl);
        console.log("  Manager     :", managerImpl);
        console.log("  Yield       :", yieldImpl);
        console.log("");
        console.log("Governance:");
        console.log("  DEFAULT_ADMIN / ADMIN -> timelock", address(timelock));
        console.log("  timelock              :", reusedTimelock ? "REUSED (shared)" : "newly deployed");
        console.log("  delay (seconds)       :", cfg.timelockDelay);
        console.log("  GUARDIAN              -> safe", cfg.safe);
        console.log("  OPERATOR              -> ", cfg.executor);
        console.log("  REBALANCER            -> ", cfg.rebalancer);
        console.log("  deployer holds        : nothing");
        console.log("");
        console.log("Parameters:");
        console.log("  asset          :", cfg.asset);
        console.log("  treasury       :", cfg.treasury);
        console.log("  cooldownPeriod :", COOLDOWN_PERIOD);
        console.log("  vestingPeriod  :", VESTING_PERIOD);
        console.log("  exit fee       :", cfg.exitFee);
        console.log("  maxRedeemCap   :", cfg.maxRedeemCap);
        console.log("  minShares      :", cfg.minShares);
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("1. Verify implementations:");
        console.log("   forge verify-contract", vaultImpl, "src/TownSqToken.sol:TownSqToken");
        console.log("   forge verify-contract", managerImpl, "src/Manager.sol:Manager");
        console.log("   forge verify-contract", yieldImpl, "src/Yield.sol:Yield");
        console.log("2. Whitelist destinations - now a 48h proposal:");
        console.log("   ./script/timelock-propose.sh propose <timelock> <manager> \\");
        console.log("     'setWhitelistedAddresses(address[],bool[])' '[<dest>]' '[true]'");
        console.log("3. Confirm the Safe can pause:");
        console.log("   cast call", address(vault), "'hasRole(bytes32,address)(bool)' \\");
        console.log("     $(cast keccak 'GUARDIAN_ROLE')", cfg.safe);
    }
}
