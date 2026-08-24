// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

// =====================================================================================
// VENDORED TEST FIXTURE — DO NOT EDIT THE LOGIC, DO NOT IMPORT FROM src/
//
// Verbatim copy of src/Yield.sol at commit b6e5b5c, the implementation live before the
// fee-split upgrade. Note that `distributeYield` here credits the WHOLE fee to
// totalAssets() while pricing the fee shares against the fully vested base — that is the
// upward share-price step the upgrade removes, preserved deliberately as the baseline.
//
// GOES STALE ON DEPLOY. Re-vendor from the live commit before testing the next upgrade.
// See test/legacy/README.md.
// =====================================================================================

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import "openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ItownSqUSDV1 as ItownSqUSD} from "./ItownSqUSDV1.sol";
import {IManager, ManageAssetAndShares} from "../../src/Interface/IManager.sol";
import {Errors} from "../../src/Errors.sol";

interface IYield {
    event DistributeYield(
        address caller, address indexed asset, address indexed receiver, uint256 amount, uint256 feeAmount, bool profit
    );
    event ManagerSet(address indexed caller, address indexed manager);
    event MinDistributionIntervalSet(address indexed admin, uint256 minDistributionInterval);
    event MaxYieldPercentageSet(address indexed admin, uint256 maxYieldPercentage);
    event MaxFeePercentage(address indexed admin, uint256 MaxFeePercentage);
    /// @notice Loss the treasury was liable for but could not cover from its share balance
    event TreasuryDebtAccrued(uint256 amount, uint256 outstanding);
    /// @notice Treasury debt settled out of a fee entitlement and routed to shareholders
    event TreasuryDebtRepaid(uint256 amount, uint256 outstanding);
}

/**
 * @title Yield
 * @dev Manages yield distribution and profit/loss accounting for vault contracts
 * @notice This contract handles the distribution of profits and losses to vault contracts
 * with vesting mechanisms and epoch-based distribution to prevent duplicates.
 */
contract YieldV1 is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IYield {
    using SafeERC20 for IERC20;

    // ============ CONSTRUCTOR ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ CONSTANTS ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");

    // ============ STATE VARIABLES ============
    mapping(bytes32 => bool) public trxns;
    uint256 public epoch;
    uint256 public profit;
    uint256 public loss;
    uint256 public maxYieldPercentage;
    uint256 public maxFeePercentage;
    uint256 public lastDistributionTime;
    address public manager;

    // Minimum time between distributions
    uint256 public minDistributionInterval;

    /// @notice Loss the treasury was liable for but could not cover with its share balance,
    /// denominated in the vault's underlying asset. Repaid out of future fee entitlements
    /// before the treasury is credited anything.
    /// @dev Appended after `minDistributionInterval` and taken out of `__gap` (50 -> 49) so
    /// the storage layout of every pre-existing variable is unchanged.
    uint256 public treasuryDebt;

    // ============ STORAGE GAP ============
    /// @dev This empty reserved space is put in place to allow future versions to add new
    /// variables without shifting down storage in the inheritance chain.
    /// See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
    uint256[49] private __gap;

    // ============ INITIALIZER ============
    /**
     * @dev Initializes the Yield contract
     * @param _admin Admin address with governance privileges
     * @param _rebalancer Rebalancer address with yield distribution privileges
     */
    function initialize(address _admin, address _rebalancer) public initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REBALANCER_ROLE, _rebalancer);
        maxYieldPercentage = 50;
        maxFeePercentage = 5000;
        minDistributionInterval = 79200;
    }

    /**
     * @dev Required by the OZ UUPS module
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ============ EXTERNAL FUNCTIONS ============
    /**
     * @dev Get current epoch
     * @return Current epoch number
     */
    function getEpoch() external view returns (uint256) {
        return epoch;
    }

    /**
     * @dev Get last distribution time
     * @return Last distribution timestamp
     */
    function getLastDistributionTime() external view returns (uint256) {
        return lastDistributionTime;
    }

    /**
     * @dev Set minimum distribution interval (admin only)
     * @param _minDistributionInterval Minimum distribution interval
     */
    function setMinDistributionInterval(uint256 _minDistributionInterval) external onlyRole(ADMIN_ROLE) {
        if (_minDistributionInterval == 0) revert Errors.InvalidPeriod();
        minDistributionInterval = _minDistributionInterval;
        emit MinDistributionIntervalSet(msg.sender, _minDistributionInterval);
    }

    function setMaxYieldPercentage(uint256 _maxYieldPercentage) public onlyRole(ADMIN_ROLE) {
        if (_maxYieldPercentage == 0 || _maxYieldPercentage > 10_000) revert Errors.InvalidAmount();
        maxYieldPercentage = _maxYieldPercentage;
        emit MaxYieldPercentageSet(msg.sender, _maxYieldPercentage);
    }

    function setMaxFeePercentage(uint256 _maxFeePercent) public onlyRole(ADMIN_ROLE) {
        if (_maxFeePercent > 10_000) revert Errors.InvalidFee();
        maxFeePercentage = _maxFeePercent;
        emit MaxFeePercentage(msg.sender, _maxFeePercent);
    }

    /**
     * @dev Set manager contract address (admin only)
     * @param _manager New manager address
     */
    function setManager(address _manager) external onlyRole(ADMIN_ROLE) {
        if (_manager == address(0)) revert Errors.InvalidAddress();
        manager = _manager;
        emit ManagerSet(msg.sender, _manager);
    }

    /**
     * @dev Distribute yield to the vault (rebalancer only)
     *
     * @notice `amount` and `feeAmount` are two SEPARATE slices of the same realised
     * profit or loss — `feeAmount` is NOT taken out of `amount`. The caller must ensure
     * `amount + feeAmount` equals the value the strategies actually realised, otherwise
     * the vault's `totalAssets()` drifts away from the assets the protocol really holds.
     * Nothing onchain can verify this: the vault has no view of strategy balances, so the
     * split is trusted input from the offchain engine.
     *
     * Example: strategies earn 5 USDC and the protocol takes 20% — call with
     * `amount = 4e6, feeAmount = 1e6`. Passing `amount = 5e6, feeAmount = 1e6` would book
     * 6 USDC of assets against 5 USDC of real yield, permanently overstating the vault.
     *
     * On profit, `amount` vests to shareholders linearly over the vault's `vestingPeriod`
     * and `feeAmount` is minted to the treasury as shares immediately. On loss, both are
     * applied instantly with no vesting, and the treasury's shares are burned to absorb
     * `feeAmount` of the loss.
     *
     * @param amount Value accruing to shareholders — profit credited or loss debited.
     *               Capped at `maxYieldPercentage` of the vault's current `totalAssets()`.
     * @param feeAmount The treasury's slice, on top of `amount`. On profit this is minted
     *                  to the treasury; on loss it is burned from it. Capped at
     *                  `maxFeePercentage` of `amount`.
     * @param nonce Sequential epoch number, must equal `epoch + 1`; prevents duplicates
     * @param isProfit Whether this is a profit (true) or loss (false)
     */
    function distributeYield(uint256 amount, uint256 feeAmount, uint256 nonce, bool isProfit)
        external
        onlyRole(REBALANCER_ROLE)
    {
        uint256 totalAssets = IERC4626(getTownSqToken()).totalAssets();
        require(amount <= (totalAssets * maxYieldPercentage / 10_000));
        require(feeAmount <= (amount * maxFeePercentage / 10_000));

        address vaultToken = IManager(manager).townSqToken();
        if (nonce != epoch + 1) revert Errors.InvalidEpoch();

        bytes32 proofHash = keccak256(abi.encode(vaultToken, amount, nonce, isProfit));
        if (trxns[proofHash]) revert Errors.DuplicateTransaction();

        // Check if enough time has passed since last distribution
        if (lastDistributionTime > 0 && lastDistributionTime + minDistributionInterval > block.timestamp) {
            revert Errors.DistributionTooFrequent();
        }

        trxns[proofHash] = true;
        epoch = nonce;
        lastDistributionTime = block.timestamp;

        if (isProfit) {
            profit += amount;

            // Outstanding treasury debt is settled before the treasury earns anything new.
            // The repaid portion is routed to shareholders instead of being minted as fee
            // shares, which is what makes them whole for the loss the treasury could not
            // absorb at the time.
            uint256 repaid = feeAmount < treasuryDebt ? feeAmount : treasuryDebt;
            if (repaid > 0) {
                treasuryDebt -= repaid;
                emit TreasuryDebtRepaid(repaid, treasuryDebt);
            }

            ItownSqUSD(vaultToken).transferInRewards(amount + repaid, true);

            uint256 netFee = feeAmount - repaid;
            if (netFee > 0) {
                // Price the fee against the FULLY VESTED asset base, not the recognised one.
                //
                // `transferInRewards` above added the profit to the vesting schedule, so
                // `totalAssets()` still excludes it. Pricing at that stale, lower value would
                // hand the treasury more shares than `netFee` is worth, and those extra shares
                // would then capture part of the holders' profit as it vests. Rescaling onto
                // `virtualAssets` (== totalAssets + unvested) makes the fee shares worth
                // exactly `netFee` once the schedule completes.
                //
                // The vault's own convertToShares is reused and only re-based, so the ERC-4626
                // virtual-share inflation protection stays intact rather than being re-derived.
                uint256 recognised = IERC4626(vaultToken).totalAssets();
                uint256 fullyVested = ItownSqUSD(vaultToken).virtualAssets();

                uint256 feeShares = IERC4626(vaultToken).convertToShares(netFee);
                if (fullyVested > recognised) {
                    feeShares = Math.mulDiv(feeShares, recognised + 1, fullyVested + 1);
                }

                ManageAssetAndShares memory manageAssetAndShares = ManageAssetAndShares({
                    vaultToken: vaultToken, shares: feeShares, assetAmount: netFee, updateAsset: true, isMint: true
                });
                IManager(manager).manageAssetAndShares(IManager(manager).treasury(), manageAssetAndShares);
            }
        } else {
            loss += amount;
            ItownSqUSD(vaultToken).transferInRewards(amount, false);

            if (feeAmount > 0) {
                address treasuryAddress = IManager(manager).treasury();

                // Clamp the clawback to what the treasury actually holds. Treasury shares are
                // ordinary ERC-20 shares it can transfer or redeem at any time, so burning
                // `feeAmount` worth unconditionally would revert the whole loss report
                // whenever the treasury has been swept -- leaving the vault priced above its
                // real value while redemptions keep settling.
                uint256 lossShares = IERC4626(vaultToken).convertToShares(feeAmount);
                uint256 available = IERC20(vaultToken).balanceOf(treasuryAddress);
                if (lossShares > available) lossShares = available;

                uint256 absorbed = IERC4626(vaultToken).convertToAssets(lossShares);
                if (lossShares > 0) {
                    ManageAssetAndShares memory manageAssetAndShares = ManageAssetAndShares({
                        vaultToken: vaultToken,
                        shares: lossShares,
                        assetAmount: absorbed,
                        updateAsset: true,
                        isMint: false
                    });
                    IManager(manager).manageAssetAndShares(treasuryAddress, manageAssetAndShares);
                }

                uint256 shortfall = feeAmount - absorbed;
                if (shortfall > 0) {
                    // The assets are gone regardless, so they are written down now and the
                    // uncovered portion is booked as a treasury obligation rather than
                    // silently socialised. Future fees repay it before the treasury is paid.
                    treasuryDebt += shortfall;
                    ItownSqUSD(vaultToken).transferInRewards(shortfall, false);
                    emit TreasuryDebtAccrued(shortfall, treasuryDebt);
                }
            }
        }

        emit DistributeYield(msg.sender, IERC4626(vaultToken).asset(), vaultToken, amount, feeAmount, isProfit);
    }

    function getTownSqToken() public view returns (address) {
        return IManager(manager).townSqToken();
    }

    function getManager() public view returns (address) {
        return manager;
    }
}
