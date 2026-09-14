// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Utils} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Yield} from "../src/Yield.sol";

/**
 * @title UpgradeVault
 * @notice Upgrades the TownSqToken vault proxy to a freshly deployed implementation.
 *
 * This is a LOGIC-ONLY upgrade: the storage layout is unchanged and there is no
 * reinitializer, so `upgradeToAndCall` is called with empty data.
 *
 * ORDERING — READ THIS IF THE YIELD CONTRACT IS ALSO BEING UPGRADED
 * ----------------------------------------------------------------
 * The fee-split change spans BOTH proxies: the new `Yield` calls `previewProfitFee`, which
 * only the new `TownSqToken` implements. Upgrade the VAULT FIRST, then Yield. In that order
 * there is no broken window — the old Yield never calls the new function. In the reverse
 * order every fee-bearing profit distribution reverts until the vault upgrade lands, and
 * zero-fee distributions keep succeeding, so the breakage is silent until the first fee epoch.
 * Use `upgradeBoth()` below to get the order right by construction.
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
    //                        BOTH PROXIES, IN THE CORRECT ORDER
    // =====================================================================================

    /// @dev State the Yield upgrade must leave untouched.
    struct YieldState {
        uint256 epoch;
        uint256 profit;
        uint256 loss;
        uint256 maxYieldPercentage;
        uint256 maxFeePercentage;
        uint256 lastDistributionTime;
        uint256 minDistributionInterval;
        uint256 treasuryDebt;
        address manager;
    }

    /**
     * @dev Upgrades BOTH proxies for the fee-split change, vault first. Use this rather than
     *      running the single-proxy paths back to back — the order is the whole point.
     *
     * Required env vars: VAULT_PROXY, YIELD_PROXY, ADMIN_PK
     *
     * Dry run:  forge script script/UpgradeVault.s.sol --sig 'upgradeBoth()' --rpc-url monad
     * Execute:  add --broadcast --slow --verify --verifier sourcify \
     *             --verifier-url 'https://sourcify-api-monad.blockvision.org/'
     */
    function upgradeBoth() external {
        address vaultProxy = vm.envAddress("VAULT_PROXY");
        address yieldProxy = vm.envAddress("YIELD_PROXY");
        uint256 adminPk = vm.envUint("ADMIN_PK");
        address admin = vm.addr(adminPk);

        TownSqToken vault = TownSqToken(vaultProxy);
        Yield yieldC = Yield(yieldProxy);

        // ---------- pre-flight ----------
        address oldVaultImpl = address(uint160(uint256(vm.load(vaultProxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        address oldYieldImpl = address(uint160(uint256(vm.load(yieldProxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(oldVaultImpl != address(0), "vault proxy has no implementation - wrong address?");
        require(oldYieldImpl != address(0), "yield proxy has no implementation - wrong address?");

        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_PK lacks DEFAULT_ADMIN_ROLE on the vault");
        require(yieldC.hasRole(yieldC.DEFAULT_ADMIN_ROLE(), admin), "ADMIN_PK lacks DEFAULT_ADMIN_ROLE on yield");

        // The two proxies must already know about each other, or the post-check below is
        // testing nothing. `manager` wires both; a mismatch means one of the addresses is wrong.
        require(yieldC.getTownSqToken() == vaultProxy, "YIELD_PROXY does not point at VAULT_PROXY");

        VaultState memory vaultBefore = _snapshot(vault);
        YieldState memory yieldBefore = _snapshotYield(yieldC);

        console.log("=== PRE-UPGRADE ===");
        console.log("Vault proxy         :", vaultProxy);
        console.log("Vault impl          :", oldVaultImpl);
        console.log("Yield proxy         :", yieldProxy);
        console.log("Yield impl          :", oldYieldImpl);
        console.log("Upgrade signer      :", admin);
        _logState(vaultBefore);
        console.log("  epoch             :", yieldBefore.epoch);
        console.log("  treasuryDebt      :", yieldBefore.treasuryDebt);

        // ---------- upgrade: VAULT FIRST ----------
        vm.startBroadcast(adminPk);

        TownSqToken newVaultImpl = new TownSqToken();
        vault.upgradeToAndCall(address(newVaultImpl), "");

        // Only now is `previewProfitFee` callable, so the new Yield can safely go live.
        Yield newYieldImpl = new Yield();
        yieldC.upgradeToAndCall(address(newYieldImpl), "");

        vm.stopBroadcast();

        // ---------- post-flight ----------
        require(
            address(uint160(uint256(vm.load(vaultProxy, ERC1967Utils.IMPLEMENTATION_SLOT)))) == address(newVaultImpl),
            "vault implementation slot was not updated"
        );
        require(
            address(uint160(uint256(vm.load(yieldProxy, ERC1967Utils.IMPLEMENTATION_SLOT)))) == address(newYieldImpl),
            "yield implementation slot was not updated"
        );

        _assertStatePreserved(vaultBefore, _snapshot(vault));
        _assertYieldStatePreserved(yieldBefore, _snapshotYield(yieldC));

        // The function the new Yield depends on must actually answer through the new vault
        // implementation. A zero fee is a safe probe: it mutates nothing.
        vault.previewProfitFee(0);

        console.log("\n=== VERIFIED ===");
        console.log("Both implementations swapped, all state preserved, previewProfitFee live.");
        console.log("Old vault impl (keep for records):", oldVaultImpl);
        console.log("Old yield impl (keep for records):", oldYieldImpl);
        console.log("New vault impl                   :", address(newVaultImpl));
        console.log("New yield impl                   :", address(newYieldImpl));
    }

    function _snapshotYield(Yield y) internal view returns (YieldState memory s) {
        s.epoch = y.epoch();
        s.profit = y.profit();
        s.loss = y.loss();
        s.maxYieldPercentage = y.maxYieldPercentage();
        s.maxFeePercentage = y.maxFeePercentage();
        s.lastDistributionTime = y.lastDistributionTime();
        s.minDistributionInterval = y.minDistributionInterval();
        s.treasuryDebt = y.treasuryDebt();
        s.manager = y.getManager();
    }

    function _assertYieldStatePreserved(YieldState memory a, YieldState memory b) internal pure {
        require(a.epoch == b.epoch, "epoch changed");
        require(a.profit == b.profit, "profit changed");
        require(a.loss == b.loss, "loss changed");
        require(a.maxYieldPercentage == b.maxYieldPercentage, "maxYieldPercentage changed");
        require(a.maxFeePercentage == b.maxFeePercentage, "maxFeePercentage changed");
        require(a.lastDistributionTime == b.lastDistributionTime, "lastDistributionTime changed");
        require(a.minDistributionInterval == b.minDistributionInterval, "minDistributionInterval changed");
        require(a.treasuryDebt == b.treasuryDebt, "treasuryDebt changed");
        require(a.manager == b.manager, "manager changed");
    }

    // =====================================================================================
    //                            MULTISIG (Safe) UPGRADE PATH
    //
    // A Safe cannot sign an EOA transaction, so `run()` above does not apply. Split it:
    //   Step 1: any EOA deploys the implementation (needs no privileges)
    //   Step 2: simulate the upgrade AS the Safe, then hand the calldata to the signers
    //
    // For the fee-split change BOTH proxies move, so use the `Both` variants:
    //   deployImplementationsBoth() -> prepareMultisigUpgradeBoth()
    // The single-proxy pair below remains for a vault-only upgrade.
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
     * @dev STEP 1 (BOTH) - deploy both new implementations from an ordinary EOA. Deploying an
     *      implementation needs no privileges and touches no proxy, so the order is irrelevant
     *      here — it is the UPGRADE order in step 2 that matters.
     *
     *   forge script script/UpgradeVault.s.sol --sig 'deployImplementationsBoth()' \
     *     --rpc-url monad --broadcast --verify --verifier sourcify \
     *     --verifier-url 'https://sourcify-api-monad.blockvision.org/'
     */
    function deployImplementationsBoth() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");

        vm.startBroadcast(pk);
        TownSqToken vaultImpl = new TownSqToken();
        Yield yieldImpl = new Yield();
        vm.stopBroadcast();

        console.log("=== STEP 1 COMPLETE ===");
        console.log("New vault implementation :", address(vaultImpl));
        console.log("New yield implementation :", address(yieldImpl));
        console.log("\nNow run step 2:");
        console.log("  NEW_VAULT_IMPL=%s \\", address(vaultImpl));
        console.log("  NEW_YIELD_IMPL=%s \\", address(yieldImpl));
        console.log("  VAULT_PROXY=0x... YIELD_PROXY=0x... ADMIN_ADDRESS=0x<safe> \\");
        console.log("  forge script script/UpgradeVault.s.sol \\");
        console.log("    --sig 'prepareMultisigUpgradeBoth()' --rpc-url monad");
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

    /**
     * @dev STEP 2b - the Safe variant of `upgradeBoth()`. Simulates both upgrades in the
     *      correct order and prints the TWO transactions to be signed, in the order they must
     *      be executed. Broadcasts nothing.
     *
     *      The Safe executes these as separate transactions, which is precisely where the
     *      ordering hazard lives: between tx 1 and tx 2 the system is fully functional, but
     *      if the signers execute them the other way round, every fee-bearing profit epoch
     *      reverts until tx 2 lands.
     *
     *   VAULT_PROXY=0x... YIELD_PROXY=0x... NEW_VAULT_IMPL=0x... NEW_YIELD_IMPL=0x... \
     *   ADMIN_ADDRESS=0x<safe> \
     *   forge script script/UpgradeVault.s.sol --sig 'prepareMultisigUpgradeBoth()' --rpc-url monad
     */
    function prepareMultisigUpgradeBoth() external {
        address vaultProxy = vm.envAddress("VAULT_PROXY");
        address yieldProxy = vm.envAddress("YIELD_PROXY");
        address newVaultImpl = vm.envAddress("NEW_VAULT_IMPL");
        address newYieldImpl = vm.envAddress("NEW_YIELD_IMPL");
        address safe = vm.envAddress("ADMIN_ADDRESS");

        TownSqToken vault = TownSqToken(vaultProxy);
        Yield yieldC = Yield(yieldProxy);

        require(newVaultImpl.code.length > 0, "NEW_VAULT_IMPL has no code - run step 1 first");
        require(newYieldImpl.code.length > 0, "NEW_YIELD_IMPL has no code - run step 1 first");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), safe), "the Safe lacks DEFAULT_ADMIN_ROLE on the vault");
        require(yieldC.hasRole(yieldC.DEFAULT_ADMIN_ROLE(), safe), "the Safe lacks DEFAULT_ADMIN_ROLE on yield");
        require(yieldC.getTownSqToken() == vaultProxy, "YIELD_PROXY does not point at VAULT_PROXY");

        VaultState memory vaultBefore = _snapshot(vault);
        YieldState memory yieldBefore = _snapshotYield(yieldC);

        // ---------- simulate in the mandated order ----------
        vm.prank(safe);
        vault.upgradeToAndCall(newVaultImpl, "");
        vm.prank(safe);
        yieldC.upgradeToAndCall(newYieldImpl, "");

        _assertStatePreserved(vaultBefore, _snapshot(vault));
        _assertYieldStatePreserved(yieldBefore, _snapshotYield(yieldC));
        vault.previewProfitFee(0); // the dependency the new Yield needs is live

        console.log("=== SIMULATION PASSED ===");
        console.log("Both upgrades succeed in order and all state is preserved.");

        console.log("\n=== SAFE TRANSACTION 1 of 2 - THE VAULT. EXECUTE THIS FIRST. ===");
        console.log("To      :", vaultProxy);
        console.log("Value   : 0");
        console.log("Arg 1   :", newVaultImpl);
        console.log("Data    :");
        console.logBytes(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newVaultImpl, bytes("")));

        console.log("\n=== SAFE TRANSACTION 2 of 2 - YIELD. ONLY AFTER TX 1 IS MINED. ===");
        console.log("To      :", yieldProxy);
        console.log("Value   : 0");
        console.log("Arg 1   :", newYieldImpl);
        console.log("Data    :");
        console.logBytes(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newYieldImpl, bytes("")));

        console.log("\n=== FOR THE SIGNERS TO CHECK INDEPENDENTLY ===");
        console.log("1. Each `To` is a PROXY, not an implementation");
        console.log("2. Tx 1 targets the vault. Executing tx 2 first breaks fee distributions");
        console.log("3. Arg 2 is empty on both - non-empty data runs arbitrary code via delegatecall");
        console.log("4. Value is 0 on both");
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

// ===================== SAFE RUNBOOK: FEE-SPLIT UPGRADE (BOTH PROXIES) =====================
//
// Step 1 - deploy both implementations from any EOA:
//
// forge script script/UpgradeVault.s.sol --sig 'deployImplementationsBoth()' \
//   --rpc-url monad --broadcast \
//   --verify --verifier sourcify \
//   --verifier-url 'https://sourcify-api-monad.blockvision.org/'
//
// Step 2 - simulate as the Safe and print BOTH transactions to sign:
//
// VAULT_PROXY=0x... YIELD_PROXY=0x... \
// NEW_VAULT_IMPL=<from step 1> NEW_YIELD_IMPL=<from step 1> ADMIN_ADDRESS=<safe> \
// forge script script/UpgradeVault.s.sol --sig 'prepareMultisigUpgradeBoth()' --rpc-url monad
//
// Step 3 - the Safe executes tx 1 (vault) and waits for it to be MINED before tx 2 (yield).
//          Reversed, fee-bearing profit epochs revert while zero-fee ones keep succeeding,
//          so the breakage is silent until the first fee epoch.
//
// ===================== SAFE RUNBOOK: VAULT-ONLY UPGRADE ===================================
//
// forge script script/UpgradeVault.s.sol --sig 'deployImplementation()' \
//   --rpc-url monad --broadcast \
//   --verify --verifier sourcify \
//   --verifier-url 'https://sourcify-api-monad.blockvision.org/'

// VAULT_PROXY=0x... NEW_IMPL=<from step 1> ADMIN_ADDRESS=<safe> \
// forge script script/UpgradeVault.s.sol --sig 'prepareMultisigUpgrade()' --rpc-url monad
