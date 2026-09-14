// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ItownSqUSD} from "./Interface/ItownSqUSD.sol";
import {IManager, ManageAssetAndShares} from "./Interface/IManager.sol";
import {Errors} from "./Errors.sol";

/**
 * @title Manager
 * @dev Manages asset deployment across multiple DeFi protocols and coordinates with vault contracts
 * @notice This contract handles the deployment of user funds across various yield-generating protocols
 * and manages the coordination between the vault and yield contracts.
 */
contract Manager is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IManager {
    using SafeERC20 for IERC20;

    // ============ CONSTRUCTOR ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ CONSTANTS ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @dev Emergency-only role. Held by a hot multisig so a compromised destination can be
    /// revoked without waiting out the timelock that governs ADMIN_ROLE. Can only REMOVE
    /// whitelist entries, never add them -- a compromised guardian can strand capital
    /// deployment, which ADMIN_ROLE can undo, but cannot create a path for funds to leave.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ============ STATE VARIABLES ============
    address public treasury;
    address public yield;
    address public townSqToken;

    mapping(address => bool) public whitelistedAddresses;
    mapping(address => uint256) public minSharesInVaultToken;
    mapping(address => uint256) public maxRedeemCap;

    // ============ STORAGE GAP ============
    /// @dev This empty reserved space is put in place to allow future versions to add new
    /// variables without shifting down storage in the inheritance chain.
    /// See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
    uint256[50] private __gap;

    // ============ INITIALIZER ============
    /**
     * @dev Initializes the Manager contract
     * @param admin Admin address with governance privileges
     * @param _yield Yield contract address
     * @param _executor Executor address with operational privileges
     */
    function initialize(address admin, address _yield, address _executor) public initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, _executor);
        yield = _yield;
    }

    /**
     * @dev Required by the OZ UUPS module
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ EXTERNAL FUNCTIONS ============
    /**
     * @dev Set treasury address (admin only)
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyRole(ADMIN_ROLE) {
        if (_treasury == address(0)) revert Errors.InvalidAddress();
        treasury = _treasury;
        emit TreasurySet(msg.sender, _treasury);
    }

    /**
     * @dev Set contract addresses (admin only)
     * @param _yield New yield address
     * @param _townSqToken New TownSqToken address
     */
    function setManagerAndYield(address _yield, address _townSqToken) external onlyRole(ADMIN_ROLE) {
        if (_yield == address(0)) revert Errors.InvalidAddress();
        if (_townSqToken == address(0)) revert Errors.InvalidAddress();

        // Never point the protocol at an address that is already a valid `execute` target.
        // Whitelisting an address while it is inert and only then promoting it to vault or
        // yield is the second way the write-time guard above can be stepped around.
        if (whitelistedAddresses[_townSqToken] || whitelistedAddresses[_yield]) {
            revert Errors.NotWhitelisted();
        }

        yield = _yield;
        townSqToken = _townSqToken;
        emit YieldSet(msg.sender, _yield);
        emit TownSqTokenSet(msg.sender, _townSqToken);
    }

    /**
     * @dev Set whitelisted addresses for external protocol interactions (admin only)
     * @param _wallets Array of wallet addresses to whitelist
     * @param _statuses Array of whitelist statuses (true = whitelisted, false = not whitelisted)
     */
    function setWhitelistedAddresses(address[] calldata _wallets, bool[] calldata _statuses)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (_wallets.length != _statuses.length) revert Errors.LengthMismatch();

        // Refuse to build a whitelist before the protocol's own addresses are known.
        // `initialize` leaves `townSqToken` at address(0), and a guard comparing against
        // address(0) waves the real vault straight through.
        if (townSqToken == address(0)) revert Errors.NotInitialized();

        for (uint256 i = 0; i < _wallets.length; i++) {
            // Security: prevent whitelisting the protocol's own contracts. `execute` calls
            // out as this contract, so any of these becoming a valid target would let
            // OPERATOR_ROLE act with the Manager's authority over vault accounting.
            //
            // Defence in depth only -- `execute` re-checks this at call time, which is what
            // actually enforces it. Keeping it here fails a misconfiguration loudly at the
            // point it is introduced rather than silently months later.
            if (
                _wallets[i] == address(0) || _wallets[i] == address(this) || _wallets[i] == townSqToken
                    || _wallets[i] == yield
            ) {
                revert Errors.NotWhitelisted();
            }
            whitelistedAddresses[_wallets[i]] = _statuses[i];
            emit WhitelistUpdated(msg.sender, _wallets[i], _statuses[i]);
        }
    }

    /**
     * @dev Revoke whitelist entries without delay (guardian or admin)
     * @notice Removal-only counterpart to `setWhitelistedAddresses`. Additions run through
     * ADMIN_ROLE and therefore the timelock, because authorising a new destination for
     * custodied funds is exactly the decision depositors deserve warning of. Removal is the
     * opposite: a destination discovered to be compromised must be cut off in the same
     * block, not in 48 hours. This function can only ever write `false`.
     * @param _wallets Addresses to revoke
     */
    function removeWhitelistedAddresses(address[] calldata _wallets) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert Errors.NotAuthorized();
        }
        for (uint256 i = 0; i < _wallets.length; i++) {
            whitelistedAddresses[_wallets[i]] = false;
            emit WhitelistUpdated(msg.sender, _wallets[i], false);
        }
    }

    /**
     * @dev Execute multiple calls to whitelisted external protocols (operator only)
     * @param targets Array of target contract addresses
     * @param data Array of call data for each target
     * @return results Array of return data from each call
     */
    function execute(address[] calldata targets, bytes[] calldata data)
        external
        onlyRole(OPERATOR_ROLE)
        returns (bytes[] memory results)
    {
        if (targets.length != data.length) revert Errors.LengthMismatch();
        results = new bytes[](data.length);

        // Cached outside the loop: neither can change while this function runs, so the
        // protocol's own addresses cost two SLOADs in total rather than two per target.
        address vaultAddr = townSqToken;
        address yieldAddr = yield;

        for (uint256 i = 0; i < data.length; i++) {
            address target = targets[i];
            if (!whitelistedAddresses[target]) {
                revert Errors.NotWhitelisted();
            }

            // Re-checked HERE, at call time, and not only where entries are written.
            // `execute` sends calls as this contract, and the vault authorises its own
            // accounting entry points on `msg.sender == manager` -- so a whitelisted vault
            // would hand OPERATOR_ROLE the power to forge `totalAssets` and mint shares.
            //
            // The write-time guard in `setWhitelistedAddresses` compares against
            // `townSqToken`, which is mutable: it is address(0) between `initialize` and
            // `setManagerAndYield`, and `setManagerAndYield` can later repoint it at an
            // address that was whitelisted while it was still inert. Either ordering leaves
            // a live entry the write-time check never sees again. Checking at the point of
            // use closes the gap, because there is no longer an interval between the check
            // and the call. See test/POC-WhitelistEscalation.t.sol.
            if (target == vaultAddr || target == yieldAddr || target == address(this)) {
                revert Errors.NotWhitelisted();
            }

            (bool success, bytes memory result) = target.call(data[i]);
            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
        emit BatchExecuted(msg.sender, targets, data);
        return results;
    }

    /**
     * @dev Redeem shares on behalf of a user (operator only)
     * @param _townSqUSD Address of the townSqUSD vault contract
     * @param _user User address to redeem for
     */
    function redeemFor(address _townSqUSD, address _user) external onlyRole(OPERATOR_ROLE) {
        ItownSqUSD(_townSqUSD).redeemFor(_user);
        emit RedemptionExecuted(msg.sender, _townSqUSD, _user);
    }

    /**
     * @dev Set minimum shares required for vault token operations (admin only)
     * @param _townSqUSD Address of the townSqUSD vault contract
     * @param _minShares Minimum shares required
     */
    function setMinSharesInVaultToken(address _townSqUSD, uint256 _minShares) external onlyRole(ADMIN_ROLE) {
        if (_minShares == 0) revert Errors.InvalidMinShares();
        minSharesInVaultToken[_townSqUSD] = _minShares;
        emit MinSharesInVaultTokenSet(msg.sender, _townSqUSD, _minShares);
    }

    /**
     * @dev Set maximum redeem cap for a vault (admin only)
     * @param _townSqUSD Address of the townSqUSD vault contract
     * @param _maxRedeemCap Maximum redeem cap
     */
    function setMaxRedeemCap(address _townSqUSD, uint256 _maxRedeemCap) external onlyRole(ADMIN_ROLE) {
        maxRedeemCap[_townSqUSD] = _maxRedeemCap;
        emit MaxRedeemCapSet(msg.sender, _townSqUSD, _maxRedeemCap);
    }

    /**
     * @dev Manage assets and shares for a vault (yield contract only)
     * @param _to Recipient address for shares
     * @param _order Order containing asset and share management details
     */
    function manageAssetAndShares(address _to, ManageAssetAndShares memory _order) external {
        if (msg.sender != yield) revert Errors.OnlyYieldContract();

        if (_order.updateAsset) {
            ItownSqUSD(_order.vaultToken).updateTotalAssets(_order.assetAmount, _order.isMint);
        }
        if (_order.isMint) {
            ItownSqUSD(_order.vaultToken).mintVaultToken(_to, _order.shares);
        } else {
            ItownSqUSD(_order.vaultToken).burnVaultToken(_to, _order.shares);
        }
        emit AssetAndShareManaged(
            msg.sender, _order.vaultToken, _order.shares, _order.assetAmount, _order.updateAsset, _order.isMint
        );
    }

    function transferToVault(address token, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        IERC20(token).safeTransfer(townSqToken, amount);
    }
}
