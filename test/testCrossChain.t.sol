// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ItownSqToken, IManager, IYield} from "./mock/interfaces.sol";
import {console2} from "forge-std/console2.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {Create2} from "openzeppelin-contracts/utils/Create2.sol";

contract forkTestDeployment is Test {
    TownSqToken public townSqUSD;
    Manager public manager;
    Yield public yield;

    // NOTE: Ethereum mainnet USDC. This address is baked into `initData` below, which is
    // part of the CREATE2 preimage — so the "same address on every chain" property this
    // test checks only holds while every chain uses THIS asset address. USDC has a
    // different address (and, on BNB Chain, different decimals) per chain. See
    // docs/KNOWN_ISSUES.md Q-12.
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address admin = 0xfa5b3614A7C8265E3e8c4f56bC123203BD155ff2;

    bytes32 public SALT = bytes32(uint256(12345));
    address create2Deployer = 0x2484D29cE8701d224C712481b46Ef82Ca5EA6C12;

    /// @dev Pinned so fork results are reproducible. Override with ETH_FORK_BLOCK.
    uint256 constant DEFAULT_ETH_FORK_BLOCK = 23198600;

    function setUp() public {}

    /// @dev Forks `chain` (key from [rpc_endpoints] in foundry.toml). Pins to `blockNumber`
    ///      when non-zero; a zero pin forks at chain head and is NOT reproducible.
    function _fork(string memory chain, uint256 blockNumber) internal {
        if (blockNumber == 0) {
            vm.createSelectFork(vm.rpcUrl(chain));
        } else {
            vm.createSelectFork(vm.rpcUrl(chain), blockNumber);
        }
    }

    function testDeploymentMonad() public {
        // No known-good pinned block for this chain — set MONAD_FORK_BLOCK to make it
        // reproducible; defaults to chain head.
        _fork("monad", vm.envOr("MONAD_FORK_BLOCK", uint256(0)));
        vm.startPrank(create2Deployer);
        townSqUSD = new TownSqToken();
        manager = new Manager();
        yield = new Yield();

        bytes memory initData = abi.encodeWithSelector(
            townSqUSD.initialize.selector,
            "townSqUSD",
            "townSqUSD",
            usdc,
            admin,
            address(manager),
            1 days, // cooldownPeriod
            7 days // vestingPeriod
        );

        address proxyAddress = Create2.deploy(
            0, // value
            SALT,
            abi.encodePacked(type(townSqProxy).creationCode, abi.encode(address(townSqUSD), initData))
        );
        // Cast to address first to avoid payable fallback issue
        townSqProxy townSqUSDProxy = townSqProxy(payable(proxyAddress));

        vm.stopPrank();
        console2.log(address(townSqUSDProxy));

        address predictedAddress = computeCreate2Address();
        console2.log("Predicted address:", predictedAddress);
    }

    function computeCreate2Address() public view returns (address) {
        bytes memory initData = abi.encodeWithSelector(
            townSqUSD.initialize.selector,
            "townSqUSD",
            "townSqUSD",
            usdc,
            admin,
            address(manager),
            1 days, // cooldownPeriod
            7 days // vestingPeriod
        );

        bytes memory constructorData = abi.encode(address(townSqUSD), initData);
        bytes memory creationCode = abi.encodePacked(type(townSqProxy).creationCode, constructorData);

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, SALT, keccak256(creationCode)));
        return address(uint160(uint256(hash)));
    }
}
