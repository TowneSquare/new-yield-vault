// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";

/**
 * @title SafeRoleChange
 * @notice Emits the X Layer fee-split upgrade + admin handover as Safe transactions.
 *
 * Broadcasts NOTHING. The Safe executes these itself. The batch simulated and asserted in
 * test/test-RoleChange.t.sol is the same sequence, in the same order.
 *
 *   forge script script/SafeRoleChange.s.sol --rpc-url xlayer
 *
 * Writes a Safe Transaction Builder JSON to safe/rolechange-xlayer.json, which can be
 * uploaded directly in the Safe UI (Apps -> Transaction Builder -> Load JSON) to execute all
 * 18 calls as ONE batched transaction.
 */
contract SafeRoleChange is Script {
    // Live X Layer (chain 196)
    address constant VAULT_PROXY = 0x5B8dC679EDAE1Ad507c433EF55d5B4bA620F1919;
    address constant YIELD_PROXY = 0xa437BD29AB51BF43C686FE1561B97cF9DeBFB524;
    address constant MANAGER_PROXY = 0xF14d5567f85c73FD309738374D5a69EB17b8387c;

    address constant NEW_VAULT_IMPL = 0xDCf4Ddb6b845D32b5a2F18399d12eD88F98656aa;
    address constant NEW_YIELD_IMPL = 0x78eE602102d07839709D925c15b565cFDf833BDc;

    address constant OLD_ADMIN = 0x131Cc6487172c86F522e1bF00A544d311a686883;
    address constant NEW_ADMIN = 0xDb0794A79e57559547Cc8eb8a51ed041656dae23;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    string constant OUT = "safe/rolechange-robinhood.json";

    bytes4 constant UPGRADE_SEL = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    bytes4 constant GRANT_SEL = bytes4(keccak256("grantRole(bytes32,address)"));
    bytes4 constant REVOKE_SEL = bytes4(keccak256("revokeRole(bytes32,address)"));

    struct Tx {
        address to;
        bytes data;
        string label;
    }

    Tx[] internal txs;

    function run() external {
        require(block.chainid == 4663, "not Robinhood - use --rpc-url robinhood");

        // ---------- pre-flight against live state ----------
        require(NEW_VAULT_IMPL.code.length > 0, "NEW_VAULT_IMPL has no code");
        require(NEW_YIELD_IMPL.code.length > 0, "NEW_YIELD_IMPL has no code");
        require(
            Yield(YIELD_PROXY).getTownSqToken() == VAULT_PROXY, "YIELD_PROXY does not point at VAULT_PROXY"
        );

        // ---------- 1-2: implementations, VAULT FIRST ----------
        // The new Yield calls previewProfitFee, which only the new vault implements. Reversed,
        // fee-bearing profit epochs revert while zero-fee ones keep succeeding, so the
        // breakage is silent until the first fee epoch.
        _add(VAULT_PROXY, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", NEW_VAULT_IMPL, bytes("")),
            "1. vault upgradeToAndCall(newVaultImpl)");
        _add(YIELD_PROXY, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", NEW_YIELD_IMPL, bytes("")),
            "2. yield upgradeToAndCall(newYieldImpl)");

        // ---------- 3: vault roles ----------
        // Grant before revoke, and revoke DEFAULT_ADMIN last, so the Safe never strips its own
        // authority partway through the batch.
        _grant(VAULT_PROXY, ADMIN_ROLE, "3. vault grant ADMIN -> new");
        _grant(VAULT_PROXY, DEFAULT_ADMIN_ROLE, "4. vault grant DEFAULT_ADMIN -> new");
        _revoke(VAULT_PROXY, ADMIN_ROLE, "5. vault revoke ADMIN <- old");
        _revoke(VAULT_PROXY, DEFAULT_ADMIN_ROLE, "6. vault revoke DEFAULT_ADMIN <- old");

        // ---------- 4: yield roles ----------
        _grant(YIELD_PROXY, ADMIN_ROLE, "7. yield grant ADMIN -> new");
        _grant(YIELD_PROXY, REBALANCER_ROLE, "8. yield grant REBALANCER -> new");
        _grant(YIELD_PROXY, DEFAULT_ADMIN_ROLE, "9. yield grant DEFAULT_ADMIN -> new");
        _revoke(YIELD_PROXY, REBALANCER_ROLE, "10. yield revoke REBALANCER <- old");
        _revoke(YIELD_PROXY, ADMIN_ROLE, "11. yield revoke ADMIN <- old");
        _revoke(YIELD_PROXY, DEFAULT_ADMIN_ROLE, "12. yield revoke DEFAULT_ADMIN <- old");

        // ---------- 5: manager roles ----------
        // Omitting these leaves the old Safe holding OPERATOR_ROLE on the address custodying
        // every deposited asset, plus the power to upgrade the Manager implementation.
        _grant(MANAGER_PROXY, ADMIN_ROLE, "13. manager grant ADMIN -> new");
        _grant(MANAGER_PROXY, OPERATOR_ROLE, "14. manager grant OPERATOR -> new");
        _grant(MANAGER_PROXY, DEFAULT_ADMIN_ROLE, "15. manager grant DEFAULT_ADMIN -> new");
        _revoke(MANAGER_PROXY, OPERATOR_ROLE, "16. manager revoke OPERATOR <- old");
        _revoke(MANAGER_PROXY, ADMIN_ROLE, "17. manager revoke ADMIN <- old");
        _revoke(MANAGER_PROXY, DEFAULT_ADMIN_ROLE, "18. manager revoke DEFAULT_ADMIN <- old");

        _print();
        _writeJson();
    }

    function _add(address to, bytes memory data, string memory label) internal {
        txs.push(Tx({to: to, data: data, label: label}));
    }

    function _grant(address target, bytes32 role, string memory label) internal {
        _add(target, abi.encodeWithSignature("grantRole(bytes32,address)", role, NEW_ADMIN), label);
    }

    function _revoke(address target, bytes32 role, string memory label) internal {
        _add(target, abi.encodeWithSignature("revokeRole(bytes32,address)", role, OLD_ADMIN), label);
    }

    function _print() internal view {
        console.log("=== X LAYER (196) ROLE CHANGE + FEE-SPLIT UPGRADE ===");
        console.log("Execute from Safe :", OLD_ADMIN);
        console.log("Handing over to   :", NEW_ADMIN);
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
        console.log("2. Tx 1 targets the vault. Tx 2 targets yield. Not the reverse");
        console.log("3. upgradeToAndCall arg 2 is empty (0x) on both - non-empty data would");
        console.log("   run arbitrary code via delegatecall");
        console.log("4. Every grantRole targets the NEW admin, every revokeRole the OLD admin");
        console.log("5. The final tx revokes DEFAULT_ADMIN from this Safe. It is irreversible");
        console.log("   from here: after it, only the new Safe can upgrade or grant");
        console.log("6. Value is 0 on all", txs.length, "transactions");
    }

    /// @dev Counts are derived from the built batch, never hardcoded, so they cannot drift out
    ///      of step with it if a call is added or removed.
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

            if (txs[i].to == VAULT_PROXY) toVault++;
            else if (txs[i].to == YIELD_PROXY) toYield++;
            else if (txs[i].to == MANAGER_PROXY) toManager++;
        }

        // Every call must be one of the three known selectors and hit one of the three known
        // proxies. A mismatch means the batch contains something unintended.
        require(upgrades + grants + revokes == txs.length, "unrecognised selector in batch");
        require(toVault + toYield + toManager == txs.length, "unrecognised target in batch");

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
        console.log("Loaded into Transaction Builder these execute as ONE Safe transaction:");
        console.log("one nonce, one signing round, one multiSend delegatecall.");
        console.log("Entered by hand instead, they are", txs.length, "separate Safe transactions,");
        console.log("each needing its own 2-of-3 signatures, and the ordering guarantee becomes");
        console.log("the signers' responsibility to maintain.");
        console.log("");
    }

    /// @dev Safe Transaction Builder format. Uses raw `data` so no ABI is needed on load.
    function _writeJson() internal {
        string memory j = string.concat(
            '{"version":"1.0","chainId":"4663","createdAt":',
            vm.toString(block.timestamp),
            ',"meta":{"name":"townSqVault fee-split upgrade + admin handover",',
            '"description":"Upgrades vault then yield to the fee-split implementations, then ',
            'rotates DEFAULT_ADMIN/ADMIN/OPERATOR/REBALANCER from the old Safe to the new Safe ',
            'across all three proxies. Order is load-bearing.",',
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

        console.log("");
        console.log("Safe Transaction Builder JSON written to:", OUT);
        console.log("Upload in the Safe UI: Apps -> Transaction Builder -> Load JSON.");
    }
}
