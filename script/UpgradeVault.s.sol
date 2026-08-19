// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Utils} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TownSqToken} from "../src/TownSqToken.sol";

/**
 * @title UpgradeVault
 * @notice Upgrades the TownSqToken vault proxy to a freshly deployed implementation.
 *
 * This is a LOGIC-ONLY upgrade: the storage layout is unchanged and there is no
 * reinitializer, so `upgradeToAndCall` is called with empty data.
 *
 * Required env vars:
 *   VAULT_PROXY  - address of the deployed TownSqToken proxy
 *   ADMIN_PK     - private key holding DEFAULT_ADMIN_ROLE on the proxy (gates _authorizeUpgrade)
 *
 * Dry run (simulates the upgrade and runs every post-check, broadcasts nothing):
 *   forge script script/UpgradeVault.s.sol --rpc-url monad
 *
 * Execute:
 *   forge script script/UpgradeVault.s.sol --rpc-url monad --broadcast --slow \
 *     --verify --verifier sourcify \
 *     --verifier-url 'https://sourcify-api-monad.blockvision.org/'
 */
contract UpgradeVault is Script {
    /// @dev State captured before the upgrade so it can be asserted unchanged afterwards.
    struct VaultState {
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

    function run() external {
        address proxy = vm.envAddress("VAULT_PROXY");
        uint256 adminPk = vm.envUint("ADMIN_PK");
        address admin = vm.addr(adminPk);

        TownSqToken vault = TownSqToken(proxy);

        // ---------- pre-flight ----------
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(oldImpl != address(0), "proxy has no implementation - wrong address?");

        // Fail fast with a clear message rather than reverting inside _authorizeUpgrade.
        require(
            vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_PK does not hold DEFAULT_ADMIN_ROLE on the proxy"
        );

        VaultState memory before = _snapshot(vault);

        console.log("=== PRE-UPGRADE ===");
        console.log("Proxy               :", proxy);
        console.log("Current impl        :", oldImpl);
        console.log("Upgrade signer      :", admin);
        _logState(before);

        // ---------- deploy + upgrade ----------
        vm.startBroadcast(adminPk);

        TownSqToken newImpl = new TownSqToken();
        console.log("\nNew implementation  :", address(newImpl));

        // Empty calldata: no reinitializer, this upgrade adds no storage.
        vault.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        // ---------- post-flight ----------
        address currentImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(currentImpl == address(newImpl), "implementation slot was not updated");
        require(currentImpl != oldImpl, "implementation did not change");

        VaultState memory nowState = _snapshot(vault);
        _assertStatePreserved(before, nowState);

        console.log("\n=== POST-UPGRADE ===");
        console.log("New impl in slot    :", currentImpl);
        _logState(nowState);

        console.log("\n=== VERIFIED ===");
        console.log("Implementation swapped and all vault state preserved.");
        console.log("\nOld implementation (keep for records):", oldImpl);
        console.log("New implementation                   :", address(newImpl));
    }

    // =====================================================================================
    //                            MULTISIG (Safe) UPGRADE PATH
    //
    // A Safe cannot sign an EOA transaction, so `run()` above does not apply. Split it:
    //   Step 1: any EOA deploys the implementation (needs no privileges)
    //   Step 2: simulate the upgrade AS the Safe, then hand the calldata to the signers
    // =====================================================================================

    /**
     * @dev STEP 1 - deploy the new implementation from an ordinary EOA.
     *
     *   forge script script/UpgradeVault.s.sol --sig 'deployImplementation()' \
     *     --rpc-url monad --broadcast --verify --verifier sourcify \
     *     --verifier-url 'https://sourcify-api-monad.blockvision.org/'
     */
    function deployImplementation() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");

        vm.startBroadcast(pk);
        TownSqToken impl = new TownSqToken();
        vm.stopBroadcast();

        console.log("=== STEP 1 COMPLETE ===");
        console.log("New implementation deployed at:", address(impl));
        console.log("\nNow run step 2 with NEW_IMPL set to that address.");
    }

    /**
     * @dev STEP 2 - simulate the upgrade as the Safe and print the calldata to be signed.
     *      Broadcasts NOTHING. Deliberately no --broadcast: the Safe executes this itself.
     *
     *   VAULT_PROXY=0x... NEW_IMPL=0x... ADMIN_ADDRESS=0x<safe> \
     *   forge script script/UpgradeVault.s.sol --sig 'prepareMultisigUpgrade()' --rpc-url monad
     */
    function prepareMultisigUpgrade() external {
        address proxy = vm.envAddress("VAULT_PROXY");
        address newImpl = vm.envAddress("NEW_IMPL");
        address safe = vm.envAddress("ADMIN_ADDRESS");

        TownSqToken vault = TownSqToken(proxy);

        // ---------- pre-flight ----------
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(oldImpl != address(0), "proxy has no implementation - wrong address?");
        require(newImpl != oldImpl, "NEW_IMPL is already the active implementation");
        require(newImpl.code.length > 0, "NEW_IMPL has no code - run step 1 first");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), safe), "the Safe does not hold DEFAULT_ADMIN_ROLE");

        VaultState memory before = _snapshot(vault);

        console.log("=== PRE-UPGRADE ===");
        console.log("Proxy               :", proxy);
        console.log("Current impl        :", oldImpl);
        console.log("Safe (upgrade auth) :", safe);
        _logState(before);

        // ---------- simulate the upgrade exactly as the Safe would perform it ----------
        vm.prank(safe);
        vault.upgradeToAndCall(newImpl, "");

        address currentImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(currentImpl == newImpl, "implementation slot was not updated");

        _assertStatePreserved(before, _snapshot(vault));

        console.log("\n=== SIMULATION PASSED ===");
        console.log("Upgrade succeeds and all vault state is preserved.");

        // ---------- the transaction the Safe must execute ----------
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));

        console.log("\n=== SAFE TRANSACTION ===");
        console.log("To      :", proxy);
        console.log("Value   : 0");
        console.log("Function: upgradeToAndCall(address,bytes)");
        console.log("Arg 1   :", newImpl);
        console.log("Arg 2   : 0x (empty - no reinitializer)");
        console.log("Data    :");
        console.logBytes(data);

        console.log("\n=== FOR THE SIGNERS TO CHECK INDEPENDENTLY ===");
        console.log("1. `To` is the vault proxy, NOT the implementation");
        console.log("2. Arg 1 matches the verified implementation from step 1");
        console.log("3. Arg 2 is empty - non-empty data would run arbitrary code via delegatecall");
        console.log("4. Value is 0");
    }

    function _snapshot(TownSqToken vault) internal view returns (VaultState memory s) {
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

    /// @dev Every one of these reads a storage slot. If the layout shifted, these break.
    function _assertStatePreserved(VaultState memory a, VaultState memory b) internal pure {
        require(keccak256(bytes(a.name)) == keccak256(bytes(b.name)), "name changed");
        require(keccak256(bytes(a.symbol)) == keccak256(bytes(b.symbol)), "symbol changed");
        require(a.decimals == b.decimals, "decimals changed");
        require(a.asset == b.asset, "asset changed");
        require(a.manager == b.manager, "manager changed");
        require(a.cooldownPeriod == b.cooldownPeriod, "cooldownPeriod changed");
        require(a.vestingPeriod == b.vestingPeriod, "vestingPeriod changed");
        require(a.vestingAmount == b.vestingAmount, "vestingAmount changed");
        require(a.lastDistributionTimestamp == b.lastDistributionTimestamp, "lastDistributionTimestamp changed");
        require(a.fee == b.fee, "fee changed");
        require(a.virtualAssets == b.virtualAssets, "virtualAssets changed");
        require(a.totalRequestedAmount == b.totalRequestedAmount, "totalRequestedAmount changed");
        require(a.totalSupply == b.totalSupply, "totalSupply changed");
        require(a.totalAssets == b.totalAssets, "totalAssets changed");
        require(a.paused == b.paused, "paused changed");
    }

    function _logState(VaultState memory s) internal pure {
        console.log("  name / symbol     :", s.name, s.symbol);
        console.log("  decimals          :", s.decimals);
        console.log("  asset             :", s.asset);
        console.log("  manager           :", s.manager);
        console.log("  cooldownPeriod    :", s.cooldownPeriod);
        console.log("  vestingPeriod     :", s.vestingPeriod);
        console.log("  fee               :", s.fee);
        console.log("  virtualAssets     :", s.virtualAssets);
        console.log("  totalRequested    :", s.totalRequestedAmount);
        console.log("  totalSupply       :", s.totalSupply);
        console.log("  totalAssets       :", s.totalAssets);
        console.log("  paused            :", s.paused);
    }
}

// forge script script/UpgradeVault.s.sol --sig 'deployImplementation()' \
//   --rpc-url monad --broadcast \
//   --verify --verifier sourcify \
//   --verifier-url 'https://sourcify-api-monad.blockvision.org/'

// VAULT_PROXY=0x... NEW_IMPL=<from step 1> ADMIN_ADDRESS=<safe> \
// forge script script/UpgradeVault.s.sol --sig 'prepareMultisigUpgrade()' --rpc-url monad
