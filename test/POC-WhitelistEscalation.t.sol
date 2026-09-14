// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {TownSqToken} from "../src/TownSqToken.sol";
import {Manager} from "../src/Manager.sol";
import {Yield} from "../src/Yield.sol";
import {townSqProxy} from "../src/Proxy.sol";
import {Errors} from "../src/Errors.sol";

/**
 * @title WhitelistEscalationPoC
 * @notice REGRESSION SUITE. Originally a proof of concept for a privilege escalation; now
 * pins the fix. Every `test_exploit_*` case asserts the attack REVERTS.
 *
 * The original finding, kept for context:
 *
 * `setWhitelistedAddresses` refuses to whitelist `townSqToken` or `yield`, because a
 * whitelisted vault would let OPERATOR_ROLE reach `updateTotalAssets` and `mintVaultToken`
 * through `execute` -- those functions authorise on `msg.sender == manager`, and `execute`
 * calls are sent BY the manager.
 *
 * The guard compares against the CURRENT values of those variables. Two orderings defeat it:
 *
 *   A. `townSqToken` is address(0) between `Manager.initialize` and `setManagerAndYield`.
 *      Whitelisting the vault address during that window is not caught.
 *   B. `setManagerAndYield` can repoint `townSqToken` to an address that is ALREADY
 *      whitelisted. Nothing re-checks the whitelist.
 *
 * Either way the entry persists and the vault becomes callable through `execute`.
 *
 * THE FIX: `execute` re-checks the target against `townSqToken` / `yield` / `address(this)`
 * at CALL time, so a stale whitelist entry is inert no matter how it was created. The
 * write-time guards were tightened too, but the call-time check is what enforces it.
 */
contract WhitelistEscalationPoC is Test {
    MockERC20 asset;
    TownSqToken vault;
    Manager manager;
    Yield yieldContract;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address rebalancer = makeAddr("rebalancer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        asset = new MockERC20("USDC", "USDC");

        vm.startPrank(admin);

        yieldContract = Yield(
            address(
                new townSqProxy(
                    address(new Yield()), abi.encodeWithSelector(Yield.initialize.selector, admin, rebalancer)
                )
            )
        );
        manager = Manager(
            address(
                new townSqProxy(
                    address(new Manager()),
                    abi.encodeWithSelector(Manager.initialize.selector, admin, address(yieldContract), operator)
                )
            )
        );
        vault = TownSqToken(
            address(
                new townSqProxy(
                    address(new TownSqToken()),
                    abi.encodeWithSelector(
                        TownSqToken.initialize.selector,
                        "townSqUSD",
                        "townSqUSD",
                        IERC20(asset),
                        admin,
                        address(manager),
                        1 days,
                        7 days
                    )
                )
            )
        );

        manager.setTreasury(treasury);
        manager.setMinSharesInVaultToken(address(vault), 1e6);
        manager.setMaxRedeemCap(address(vault), type(uint256).max);
        yieldContract.setManager(address(manager));

        vm.stopPrank();

        asset.mint(alice, 1_000_000e6);
        asset.mint(bob, 1_000_000e6);
    }

    /// @dev Wire the manager -> vault reference. Deliberately separate from setUp so each
    ///      test controls when it happens relative to whitelisting.
    function _wire() internal {
        vm.prank(admin);
        manager.setManagerAndYield(address(yieldContract), address(vault));
    }

    function _whitelist(address target) internal {
        address[] memory wallets = new address[](1);
        wallets[0] = target;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        vm.prank(admin);
        manager.setWhitelistedAddresses(wallets, statuses);
    }

    /// @dev Writes a whitelist entry straight to storage, bypassing every setter.
    ///
    /// This is how the exploit tests below arm themselves now that the write-time guards
    /// reject both orderings. It models a worst case the setters can no longer produce --
    /// an entry created before the fix shipped, or via some ordering nobody has thought of
    /// -- and proves `execute` refuses the target regardless of how the entry got there.
    /// `whitelistedAddresses` is slot 3 (forge inspect Manager storage-layout).
    function _forceWhitelist(address target) internal {
        vm.store(address(manager), keccak256(abi.encode(target, uint256(3))), bytes32(uint256(1)));
        assertTrue(manager.whitelistedAddresses(target), "force-write failed");
    }

    function _exec(address target, bytes memory data) internal {
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        vm.prank(operator);
        manager.execute(targets, payloads);
    }

    // ==================================================================
    // The guard works when the ordering is the intended one
    // ==================================================================

    function test_guard_blocksWhitelistingTheVault_whenWiredFirst() public {
        _wire();

        address[] memory wallets = new address[](1);
        wallets[0] = address(vault);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(admin);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.setWhitelistedAddresses(wallets, statuses);
    }

    // ==================================================================
    // Bypass A: whitelist before the vault reference is set
    // ==================================================================

    function test_bypassA_isNowBlocked_cannotWhitelistBeforeWiring() public {
        assertEq(manager.townSqToken(), address(0), "precondition: vault not yet wired");

        address[] memory wallets = new address[](1);
        wallets[0] = address(vault);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        // Whitelisting is refused entirely until the protocol's own addresses are known.
        vm.prank(admin);
        vm.expectRevert(Errors.NotInitialized.selector);
        manager.setWhitelistedAddresses(wallets, statuses);

        assertFalse(manager.whitelistedAddresses(address(vault)), "vault got whitelisted");
    }

    function test_guard_rejectsSelfAndZero() public {
        _wire();

        address[] memory wallets = new address[](1);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        wallets[0] = address(manager);
        vm.prank(admin);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.setWhitelistedAddresses(wallets, statuses);

        wallets[0] = address(0);
        vm.prank(admin);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.setWhitelistedAddresses(wallets, statuses);
    }

    // ==================================================================
    // Bypass B: repoint the vault to an already-whitelisted address
    // ==================================================================

    function test_bypassB_isNowBlocked_cannotRepointToWhitelistedAddress() public {
        _wire();

        // A second vault, whitelisted while it is not yet the live one.
        TownSqToken other = TownSqToken(
            address(
                new townSqProxy(
                    address(new TownSqToken()),
                    abi.encodeWithSelector(
                        TownSqToken.initialize.selector,
                        "v2",
                        "v2",
                        IERC20(asset),
                        admin,
                        address(manager),
                        1 days,
                        7 days
                    )
                )
            )
        );

        _whitelist(address(other)); // still allowed: `other` is not the current townSqToken

        // But promoting an already-whitelisted address to vault is now refused.
        vm.prank(admin);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.setManagerAndYield(address(yieldContract), address(other));

        assertEq(manager.townSqToken(), address(vault), "vault was repointed");
    }

    // ==================================================================
    // The attacks the guard exists to stop -- now blocked at call time
    // ==================================================================

    /// @notice Forging totalAssets() is refused even with a live whitelist entry.
    function test_exploit_operatorCannotForgeTotalAssets() public {
        _wire();
        _forceWhitelist(address(vault)); // worst case: an entry the setters can no longer create

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(TownSqToken.updateTotalAssets.selector, 900_000e6, true);

        vm.prank(operator);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.execute(targets, payloads);

        assertEq(vault.totalAssets(), assetsBefore, "totalAssets was forged");
    }

    /// @notice Minting unbacked shares to the treasury is refused.
    function test_exploit_operatorCannotMintSharesToTreasury() public {
        _wire();
        _forceWhitelist(address(vault));

        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 supplyBefore = vault.totalSupply();

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(TownSqToken.mintVaultToken.selector, treasury, 1_000_000e18);

        vm.prank(operator);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.execute(targets, payloads);

        assertEq(vault.totalSupply(), supplyBefore, "shares were minted");
        assertEq(vault.balanceOf(treasury), 0, "treasury was credited");
    }

    /// @notice The yield contract is equally unreachable.
    function test_exploit_operatorCannotReachYield() public {
        _wire();
        _forceWhitelist(address(yieldContract));

        address[] memory targets = new address[](1);
        targets[0] = address(yieldContract);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(Yield.setManager.selector, address(0xdead));

        vm.prank(operator);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.execute(targets, payloads);
    }

    /// @notice And so is the Manager itself.
    function test_exploit_operatorCannotReachManagerItself() public {
        _wire();
        _forceWhitelist(address(manager));

        address[] memory targets = new address[](1);
        targets[0] = address(manager);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSelector(Manager.setTreasury.selector, address(0xdead));

        vm.prank(operator);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.execute(targets, payloads);

        assertEq(manager.treasury(), treasury, "treasury was redirected");
    }

    /// @notice A blocked target reverts the WHOLE batch, so it cannot be smuggled in
    ///         alongside legitimate calls.
    function test_exploit_blockedTargetRevertsEntireBatch() public {
        _wire();
        _forceWhitelist(address(vault));
        _whitelist(address(asset)); // a genuinely legitimate target

        asset.mint(address(manager), 1000e6);

        address[] memory targets = new address[](2);
        targets[0] = address(asset);
        targets[1] = address(vault);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSignature("transfer(address,uint256)", bob, 100e6);
        payloads[1] = abi.encodeWithSelector(TownSqToken.updateTotalAssets.selector, 900_000e6, true);

        uint256 bobBefore = asset.balanceOf(bob);

        vm.prank(operator);
        vm.expectRevert(Errors.NotWhitelisted.selector);
        manager.execute(targets, payloads);

        assertEq(asset.balanceOf(bob), bobBefore, "legitimate leg applied despite revert");
    }

    // ==================================================================
    // Legitimate use still works
    // ==================================================================

    function test_execute_stillWorksForRealTargets() public {
        _wire();
        _whitelist(address(asset));
        asset.mint(address(manager), 1000e6);

        address[] memory targets = new address[](1);
        targets[0] = address(asset);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeWithSignature("transfer(address,uint256)", bob, 100e6);

        uint256 bobBefore = asset.balanceOf(bob);
        vm.prank(operator);
        manager.execute(targets, payloads);

        assertEq(asset.balanceOf(bob) - bobBefore, 100e6, "legitimate execute broke");
    }
}
