// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployTimelock
 * @notice Deploys the TimelockController that will hold DEFAULT_ADMIN_ROLE and ADMIN_ROLE
 * across the vault, manager and yield proxies.
 *
 *   forge script script/DeployTimelock.s.sol --rpc-url <chain> --broadcast
 *
 * Deploys ONLY. Role migration is a separate, reviewable Safe batch -- see
 * script/TimelockRoleChange.s.sol. Splitting them means the timelock exists and can be
 * inspected onchain before anything is handed to it.
 *
 * Required env:
 *   DEPLOYER_PK    deploying key
 *   SAFE_ADDRESS   multisig that will propose, execute and cancel
 */
contract DeployTimelockScript is Script {
    /// @dev 48h. Long enough that a depositor who sees a proposal can complete a full exit
    /// before it lands: cooldownPeriod is capped at 7 days but currently 1 day, so 48h
    /// covers request + cooldown + collect with margin.
    uint256 public constant MIN_DELAY = 48 hours;

    function run() external returns (TimelockController timelock) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address safe = vm.envAddress("SAFE_ADDRESS");

        require(safe != address(0), "SAFE_ADDRESS unset");
        require(safe.code.length > 0, "SAFE_ADDRESS has no code - expected a multisig");

        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        // Same address executes. Passing address(0) here would make execution permissionless
        // -- anyone could push a matured proposal through. That is a legitimate choice for
        // public governance, but here it would let a third party time execution into a
        // moment of their choosing, so execution stays with the Safe.
        address[] memory executors = new address[](1);
        executors[0] = safe;

        vm.startBroadcast(deployerPk);

        // admin == address(0): no SEPARATE administrator. The Safe's proposer and executor
        // rights are granted above and are all it needs; an optional admin would be a
        // standing bypass of the delay this contract exists to enforce.
        //
        // Note this does not mean DEFAULT_ADMIN_ROLE is unheld: OZ v5 always grants it to
        // the timelock itself. Role and delay changes therefore remain possible, but only
        // as a proposal that has served the full delay.
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        vm.stopBroadcast();

        console.log("TimelockController :", address(timelock));
        console.log("minDelay (seconds) :", MIN_DELAY);
        console.log("proposer / executor:", safe);
        console.log("");
        console.log("Next: script/TimelockRoleChange.s.sol to migrate roles.");

        _assertConfigured(timelock, safe, vm.addr(deployerPk));
    }

    /// @dev Renamed parameter: `timelock` would shadow the named return value above.
    function _assertConfigured(TimelockController tl, address safe, address deployer) internal view {
        require(tl.getMinDelay() == MIN_DELAY, "minDelay mismatch");
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe), "safe is not proposer");
        require(tl.hasRole(tl.CANCELLER_ROLE(), safe), "safe is not canceller");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), safe), "safe is not executor");

        // No EXTERNAL account may hold DEFAULT_ADMIN_ROLE -- such an address could grant
        // itself PROPOSER and EXECUTOR and push a change through with no delay at all.
        //
        // Checked against the deployer and the Safe, NOT `address(this)`. Under `forge
        // script` the broadcasting account is `vm.addr(deployerPk)`; `address(this)` is the
        // script contract, which is never granted anything, so asserting on it always
        // passes and verifies nothing.
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer), "deployer holds timelock DEFAULT_ADMIN");
        require(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), safe), "safe holds timelock DEFAULT_ADMIN");

        // The timelock DOES hold DEFAULT_ADMIN_ROLE over itself -- OZ v5 grants it in the
        // constructor ("self administration"), regardless of the `admin` argument. That is
        // correct and required: it is how `updateDelay` and role changes happen, and being
        // the timelock, it can only act on a proposal that has served its delay.
        //
        // Asserted rather than assumed so a future OZ version that drops self-administration
        // -- leaving the delay and role set permanently frozen -- fails here instead of
        // silently shipping.
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock cannot administer itself");
    }
}
