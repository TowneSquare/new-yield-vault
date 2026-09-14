// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title TimelockRoleChange
 * @notice Emits the Safe batch that puts governance behind the TimelockController.
 *
 *   forge script script/TimelockRoleChange.s.sol --rpc-url <chain>
 *
 * Broadcasts NOTHING. Writes a Safe Transaction Builder JSON to safe/timelock-handover.json
 * for upload in the Safe UI (Apps -> Transaction Builder -> Load JSON).
 *
 * What this batch does, in order:
 *   1. Upgrades vault and manager to implementations that know GUARDIAN_ROLE.
 *   2. Grants GUARDIAN_ROLE to the Safe, so the emergency path exists BEFORE the Safe
 *      gives up ADMIN_ROLE. Reversed, there is a window with no working pause.
 *   3. Grants DEFAULT_ADMIN_ROLE and ADMIN_ROLE to the timelock on all three proxies.
 *   4. Revokes both from the Safe, DEFAULT_ADMIN last.
 *
 * OPERATOR_ROLE and REBALANCER_ROLE are deliberately untouched. They are operational, not
 * governance: a 48-hour delay on `execute` or `distributeYield` would break the protocol's
 * normal functioning, and neither can change the rules.
 *
 * Required env:
 *   TIMELOCK_ADDRESS   deployed TimelockController
 *   SAFE_ADDRESS       current admin multisig, becomes proposer/executor/guardian
 *   VAULT_PROXY, MANAGER_PROXY, YIELD_PROXY
 *   NEW_VAULT_IMPL, NEW_MANAGER_IMPL
 */
contract TimelockRoleChange is Script {
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    bytes4 constant UPGRADE_SEL = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    bytes4 constant GRANT_SEL = bytes4(keccak256("grantRole(bytes32,address)"));
    bytes4 constant REVOKE_SEL = bytes4(keccak256("revokeRole(bytes32,address)"));

    string constant OUT = "safe/timelock-handover.json";

    struct Tx {
        address to;
        bytes data;
        string label;
    }

    Tx[] internal txs;

    address internal timelock;
    address internal safe;
    address internal vaultProxy;
    address internal managerProxy;
    address internal yieldProxy;

    function run() external {
        timelock = vm.envAddress("TIMELOCK_ADDRESS");
        safe = vm.envAddress("SAFE_ADDRESS");
        vaultProxy = vm.envAddress("VAULT_PROXY");
        managerProxy = vm.envAddress("MANAGER_PROXY");
        yieldProxy = vm.envAddress("YIELD_PROXY");

        address newVaultImpl = vm.envAddress("NEW_VAULT_IMPL");
        address newManagerImpl = vm.envAddress("NEW_MANAGER_IMPL");

        // ---------- pre-flight against live state ----------
        require(timelock.code.length > 0, "TIMELOCK_ADDRESS has no code");
        require(newVaultImpl.code.length > 0, "NEW_VAULT_IMPL has no code");
        require(newManagerImpl.code.length > 0, "NEW_MANAGER_IMPL has no code");
        require(timelock != safe, "timelock must not be the Safe");

        // ---------- 1-2: implementations that know GUARDIAN_ROLE ----------
        _add(
            vaultProxy,
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newVaultImpl, bytes("")),
            "1. vault upgradeToAndCall(newVaultImpl)"
        );
        _add(
            managerProxy,
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newManagerImpl, bytes("")),
            "2. manager upgradeToAndCall(newManagerImpl)"
        );

        // ---------- 3-4: guardian first ----------
        // Granted BEFORE any ADMIN_ROLE is revoked. If the Safe gave up ADMIN first, there
        // would be a window in which nothing on earth could pause the vault.
        _grant(vaultProxy, GUARDIAN_ROLE, safe, "3. vault grant GUARDIAN -> safe");
        _grant(managerProxy, GUARDIAN_ROLE, safe, "4. manager grant GUARDIAN -> safe");

        // ---------- 5-10: hand governance to the timelock ----------
        _grant(vaultProxy, ADMIN_ROLE, timelock, "5. vault grant ADMIN -> timelock");
        _grant(vaultProxy, DEFAULT_ADMIN_ROLE, timelock, "6. vault grant DEFAULT_ADMIN -> timelock");
        _grant(managerProxy, ADMIN_ROLE, timelock, "7. manager grant ADMIN -> timelock");
        _grant(managerProxy, DEFAULT_ADMIN_ROLE, timelock, "8. manager grant DEFAULT_ADMIN -> timelock");
        _grant(yieldProxy, ADMIN_ROLE, timelock, "9. yield grant ADMIN -> timelock");
        _grant(yieldProxy, DEFAULT_ADMIN_ROLE, timelock, "10. yield grant DEFAULT_ADMIN -> timelock");

        // ---------- 11-16: strip the Safe's governance rights ----------
        // ADMIN before DEFAULT_ADMIN on each proxy: DEFAULT_ADMIN is what authorises the
        // revokes themselves, so it goes last or the batch cuts its own feet off.
        _revoke(vaultProxy, ADMIN_ROLE, safe, "11. vault revoke ADMIN <- safe");
        _revoke(vaultProxy, DEFAULT_ADMIN_ROLE, safe, "12. vault revoke DEFAULT_ADMIN <- safe");
        _revoke(managerProxy, ADMIN_ROLE, safe, "13. manager revoke ADMIN <- safe");
        _revoke(managerProxy, DEFAULT_ADMIN_ROLE, safe, "14. manager revoke DEFAULT_ADMIN <- safe");
        _revoke(yieldProxy, ADMIN_ROLE, safe, "15. yield revoke ADMIN <- safe");
        _revoke(yieldProxy, DEFAULT_ADMIN_ROLE, safe, "16. yield revoke DEFAULT_ADMIN <- safe");

        _print();
        _writeJson();
    }

    function _add(address to, bytes memory data, string memory label) internal {
        txs.push(Tx({to: to, data: data, label: label}));
    }

    function _grant(address target, bytes32 role, address to, string memory label) internal {
        _add(target, abi.encodeWithSignature("grantRole(bytes32,address)", role, to), label);
    }

    function _revoke(address target, bytes32 role, address from, string memory label) internal {
        _add(target, abi.encodeWithSignature("revokeRole(bytes32,address)", role, from), label);
    }

    function _print() internal view {
        console.log("=== TIMELOCK HANDOVER ===");
        console.log("Execute from Safe :", safe);
        console.log("Timelock          :", timelock);
        console.log("Transactions      :", txs.length);
        console.log("");
        console.log("ORDER IS LOAD-BEARING. Execute exactly as listed.");
        console.log("");

        for (uint256 i = 0; i < txs.length; i++) {
            console.log(txs[i].label);
            console.log("   to    :", txs[i].to);
            console.log("   value : 0");
            console.log("   data  :");
            console.logBytes(txs[i].data);
            console.log("");
        }

        _summary();

        console.log("=== FOR THE SIGNERS TO CHECK INDEPENDENTLY ===");
        console.log("1. Every `to` is one of the three PROXIES, never an implementation");
        console.log("2. upgradeToAndCall arg 2 is empty (0x) on both - non-empty data would");
        console.log("   run arbitrary code via delegatecall");
        console.log("3. GUARDIAN is granted to the SAFE (txs 3-4), before any revoke");
        console.log("4. ADMIN and DEFAULT_ADMIN are granted to the TIMELOCK, not the Safe");
        console.log("5. OPERATOR and REBALANCER appear NOWHERE - they stay as they are");
        console.log("6. The last tx revokes DEFAULT_ADMIN from this Safe. After it, every");
        console.log("   governance action takes 48h and the Safe can only propose");
        console.log("7. Value is 0 on all", txs.length, "transactions");
        console.log("");
        console.log("AFTER EXECUTING, VERIFY:");
        console.log("  cast call <proxy> 'hasRole(bytes32,address)(bool)' \\");
        console.log("    $(cast keccak 'ADMIN_ROLE') <timelock>   # expect true");
        console.log("  cast call <proxy> 'hasRole(bytes32,address)(bool)' \\");
        console.log("    $(cast keccak 'ADMIN_ROLE') <safe>       # expect FALSE");
    }

    /// @dev Counts derived from the built batch, never hardcoded, so they cannot drift.
    function _summary() internal view {
        uint256 upgrades;
        uint256 grants;
        uint256 revokes;
        uint256 toVault;
        uint256 toYield;
        uint256 toManager;

        for (uint256 i = 0; i < txs.length; i++) {
            bytes4 sel = bytes4(txs[i].data);
            if (sel == UPGRADE_SEL) upgrades++;
            else if (sel == GRANT_SEL) grants++;
            else if (sel == REVOKE_SEL) revokes++;

            if (txs[i].to == vaultProxy) toVault++;
            else if (txs[i].to == yieldProxy) toYield++;
            else if (txs[i].to == managerProxy) toManager++;
        }

        require(upgrades + grants + revokes == txs.length, "unrecognised selector in batch");
        require(toVault + toYield + toManager == txs.length, "unrecognised target in batch");

        // The batch must never touch the operational roles.
        for (uint256 i = 0; i < txs.length; i++) {
            bytes4 sel = bytes4(txs[i].data);
            if (sel != GRANT_SEL && sel != REVOKE_SEL) continue;
            bytes memory d = txs[i].data;
            bytes32 role;
            assembly {
                role := mload(add(d, 36))
            }
            require(role != OPERATOR_ROLE, "batch touches OPERATOR_ROLE");
            require(role != REBALANCER_ROLE, "batch touches REBALANCER_ROLE");
        }

        console.log("=== BATCH SUMMARY ===");
        console.log("TOTAL SAFE TRANSACTIONS :", txs.length);
        console.log("");
        console.log("By call:");
        console.log("  upgradeToAndCall      :", upgrades);
        console.log("  grantRole             :", grants);
        console.log("  revokeRole            :", revokes);
        console.log("By target:");
        console.log("  vault proxy           :", toVault);
        console.log("  yield proxy           :", toYield);
        console.log("  manager proxy         :", toManager);
        console.log("");
    }

    /// @dev Safe Transaction Builder format. Uses raw `data` so no ABI is needed on load.
    function _writeJson() internal {
        string memory j = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp),
            ',"meta":{"name":"townSqVault timelock handover",',
            '"description":"Upgrades vault and manager to guardian-aware implementations, ',
            "grants GUARDIAN_ROLE to the Safe, moves DEFAULT_ADMIN/ADMIN to the ",
            "TimelockController on all three proxies, then revokes both from the Safe. ",
            'OPERATOR and REBALANCER are untouched. Order is load-bearing.",',
            '"txBuilderVersion":"1.16.5"},"transactions":['
        );

        for (uint256 i = 0; i < txs.length; i++) {
            j = string.concat(
                j,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(txs[i].to),
                '","value":"0","data":"',
                vm.toString(txs[i].data),
                '"}'
            );
        }

        j = string.concat(j, "]}");
        vm.writeFile(OUT, j);
        console.log("Wrote", OUT);
    }
}
