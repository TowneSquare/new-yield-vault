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

        // admin == address(0): no separate timelock administrator. The Safe's proposer and
        // executor rights are granted above and are all it needs; leaving an admin would be
        // a standing bypass of the delay this contract exists to enforce.
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        vm.stopBroadcast();

        console.log("TimelockController :", address(timelock));
        console.log("minDelay (seconds) :", MIN_DELAY);
        console.log("proposer / executor:", safe);
        console.log("");
        console.log("Next: script/TimelockRoleChange.s.sol to migrate roles.");

        _assertConfigured(timelock, safe);
    }

    function _assertConfigured(TimelockController timelock, address safe) internal view {
        require(timelock.getMinDelay() == MIN_DELAY, "minDelay mismatch");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), safe), "safe is not proposer");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), safe), "safe is not canceller");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), safe), "safe is not executor");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer retains timelock admin");
    }
}
