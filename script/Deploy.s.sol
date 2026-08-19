// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPrivateKey);
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address executor = vm.envAddress("EXECUTOR_ADDRESS");
        address rebalancer = vm.envAddress("REBALANCER_ADDRESS");
        address assetAddress = vm.envAddress("ASSET_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 maxRedeemCap = vm.envUint("MAX_REDEEM_CAP");
        uint256 minShares = vm.envUint("MIN_SHARES");
        uint256 vestingPeriod = 604800;
        uint256 cooldownPeriod = 86400;

        console.log("Deploying to Testnet...");
        console.log("Deployer address:", deployerPrivateKey);

        // Broadcast with the key itself, not the address: the address overload requires a
        // signer to be supplied on the command line (--private-key / --account / --ledger).
        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contracts
        console.log("Deploying implementation contracts...");
        TownSqToken townSqTokenImpl = new TownSqToken();
        Manager managerImpl = new Manager();
        Yield yieldImpl = new Yield();

        console.log("TownSqToken Implementation deployed at:", address(townSqTokenImpl));
        console.log("Manager Implementation deployed at:", address(managerImpl));
        console.log("Yield Implementation deployed at:", address(yieldImpl));

        // Deploy proxies using UUPS pattern
        console.log("Deploying proxies...");

        // 1. Deploy Yield with admin and rebalancer
        bytes memory yieldInitData = abi.encodeWithSelector(
            Yield.initialize.selector,
            deployer, // admin
            rebalancer // rebalancer
        );

        townSqProxy yieldProxy = new townSqProxy(address(yieldImpl), yieldInitData);
        console.log("Yield Proxy deployed at:", address(yieldProxy));

        // 2. Deploy Manager with admin, yield, and executor
        bytes memory managerInitData = abi.encodeWithSelector(
            Manager.initialize.selector,
            deployer, // admin
            address(yieldProxy), // yield
            executor // executor
        );

        townSqProxy managerProxy = new townSqProxy(address(managerImpl), managerInitData);
        console.log("Manager Proxy deployed at:", address(managerProxy));

        console.log("Asset address:", assetAddress);
        console.log("Treasury address:", treasury);
        console.log("Max redeem cap:", maxRedeemCap);
        console.log("Min shares:", minShares);

        // 3. Deploy TownSqToken with asset, admin, and manager
        bytes memory townSqTokenInitData = abi.encodeWithSelector(
            TownSqToken.initialize.selector,
            "trwaUSDi",
            "trwaUSDi",
            IERC20(assetAddress), // asset
            admin, // admin
            address(managerProxy),
            cooldownPeriod,
            vestingPeriod
        );

        townSqProxy townSqTokenProxy = new townSqProxy(address(townSqTokenImpl), townSqTokenInitData);
        console.log("TownSqToken Proxy deployed at:", address(townSqTokenProxy));

        // Set up cross-references
        console.log("Setting up cross-references...");

        // Set manager in Yield
        Yield(address(yieldProxy)).setManager(address(managerProxy));

        // Configure Manager: set treasury, TownSqToken, yield, and vault parameters
        Manager(address(managerProxy)).setTreasury(treasury);
        Manager(address(managerProxy)).setManagerAndYield(address(yieldProxy), address(townSqTokenProxy));
        Manager(address(managerProxy)).setMinSharesInVaultToken(address(townSqTokenProxy), minShares);
        Manager(address(managerProxy)).setMaxRedeemCap(address(townSqTokenProxy), maxRedeemCap);

        // Grant roles
        console.log("Granting roles to ADMIN.");
        Manager(address(managerProxy)).grantRole(Manager(address(managerProxy)).ADMIN_ROLE(), admin);
        Manager(address(managerProxy)).grantRole(Manager(address(managerProxy)).DEFAULT_ADMIN_ROLE(), admin);
        Yield(address(yieldProxy)).grantRole(Yield(address(yieldProxy)).ADMIN_ROLE(), admin);
        Yield(address(yieldProxy)).grantRole(Yield(address(yieldProxy)).DEFAULT_ADMIN_ROLE(), admin);

        // revoke roles:
        Manager(address(managerProxy)).revokeRole(Manager(address(managerProxy)).ADMIN_ROLE(), deployer);
        Manager(address(managerProxy)).revokeRole(Manager(address(managerProxy)).DEFAULT_ADMIN_ROLE(), deployer);
        Yield(address(yieldProxy)).revokeRole(Yield(address(yieldProxy)).ADMIN_ROLE(), deployer);
        Yield(address(yieldProxy)).revokeRole(Yield(address(yieldProxy)).DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETED SUCCESSFULLY ===");
        console.log("Deployer:", deployer);
        console.log("\nContract Addresses:");
        console.log("TownSqToken Implementation:", address(townSqTokenImpl));
        console.log("TownSqToken Proxy:", address(townSqTokenProxy));
        console.log("Manager Implementation:", address(managerImpl));
        console.log("Manager Proxy:", address(managerProxy));
        console.log("Yield Implementation:", address(yieldImpl));
        console.log("Yield Proxy:", address(yieldProxy));
        console.log("\nAsset Address:", assetAddress);
        console.log("Treasury Address:", treasury);
        console.log("Max Redeem Cap:", maxRedeemCap);
        console.log("Min Shares:", minShares);
        console.log("\n=== VERIFICATION COMMANDS ===");
        console.log("To verify contracts on block explorer, use:");
        console.log("forge verify-contract", address(townSqTokenImpl), "src/TownSqToken.sol:TownSqToken");
        console.log("forge verify-contract", address(managerImpl), "src/Manager.sol:Manager");
        console.log("forge verify-contract", address(yieldImpl), "src/Yield.sol:Yield");
    }
}
