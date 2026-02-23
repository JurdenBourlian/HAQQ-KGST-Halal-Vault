// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./ShariahGuard.sol";
import "./StrategyRouter.sol";

contract HalalVault is ERC4626, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    ShariahGuard public shariahGuard;
    StrategyRouter public strategyRouter;

    uint256 public constant MAX_WITHDRAWAL_PERCENT = 1000;
    uint256 public constant MIN_FIRST_DEPOSIT = 1e6;
    uint256 public constant DEPOSIT_LOCK_TIME = 1 hours;
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_ASSETS = 1;

    mapping(uint256 => uint256) public withdrawnThisPeriod;
    mapping(uint256 => uint256) public tvlSnapshot;
    uint256 public lastSnapshotPeriod;
    mapping(address => uint256) public lastDepositTime;

    error InsufficientLiquidity(uint256 requested, uint256 available);
    error WithdrawalLimitExceeded(uint256 requested, uint256 limit);
    error WithdrawalLocked(uint256 unlockTime);
    error ZeroAddress(string param);
    error FirstDepositTooSmall(uint256 minimum);

    event ShariahGuardUpdated(address indexed newGuard);
    event StrategyRouterUpdated(address indexed newRouter);
    event BridgeDeposit(
        address indexed bridge,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event TvlSnapshotTaken(uint256 period, uint256 tvl);

    modifier updateSnapshot() {
        uint256 currentPeriod = block.timestamp / 1 days;
        if (currentPeriod > lastSnapshotPeriod) {
            tvlSnapshot[currentPeriod] = totalAssets();
            lastSnapshotPeriod = currentPeriod;
            emit TvlSnapshotTaken(currentPeriod, tvlSnapshot[currentPeriod]);
        }
        _;
    }

    constructor(
        IERC20 _asset,
        address _shariahGuard,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        if (address(_asset) == address(0)) revert ZeroAddress("asset");
        if (_shariahGuard == address(0)) revert ZeroAddress("shariahGuard");

        shariahGuard = ShariahGuard(_shariahGuard);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        if (address(strategyRouter) != address(0)) {
            total += strategyRouter.totalValue();
        }
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) 
        internal view override returns (uint256) 
    {
        uint256 supply = totalSupply() + VIRTUAL_SHARES;
        uint256 totalAssets_ = totalAssets() + VIRTUAL_ASSETS;
        return assets.mulDiv(supply, totalAssets_, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) 
        internal view override returns (uint256) 
    {
        uint256 supply = totalSupply() + VIRTUAL_SHARES;
        uint256 totalAssets_ = totalAssets() + VIRTUAL_ASSETS;
        return shares.mulDiv(totalAssets_, supply, rounding);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 period = block.timestamp / 1 days;
        uint256 tvl = tvlSnapshot[period] != 0
            ? tvlSnapshot[period]
            : totalAssets();
        uint256 dailyLimit = (tvl * MAX_WITHDRAWAL_PERCENT) / 10000;
        uint256 used = withdrawnThisPeriod[period];
        uint256 remaining = used >= dailyLimit ? 0 : dailyLimit - used;
        return ownerAssets < remaining ? ownerAssets : remaining;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return convertToShares(maxWithdraw(owner));
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        updateSnapshot
        returns (uint256)
    {
        if (totalSupply() == 0 && assets < MIN_FIRST_DEPOSIT) {
            revert FirstDepositTooSmall(MIN_FIRST_DEPOSIT);
        }
        shariahGuard.checkCompliance(msg.sender, bytes32(0), assets);
        lastDepositTime[receiver] = block.timestamp;
        return super.deposit(assets, receiver);
    }

    function depositWithRegion(
        uint256 assets,
        address receiver,
        bytes32 regionId
    ) external nonReentrant whenNotPaused updateSnapshot returns (uint256) {
        if (totalSupply() == 0 && assets < MIN_FIRST_DEPOSIT) {
            revert FirstDepositTooSmall(MIN_FIRST_DEPOSIT);
        }
        shariahGuard.checkCompliance(msg.sender, regionId, assets);
        lastDepositTime[receiver] = block.timestamp;
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        updateSnapshot
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        if (totalSupply() == 0 && assets < MIN_FIRST_DEPOSIT) {
            revert FirstDepositTooSmall(MIN_FIRST_DEPOSIT);
        }
        shariahGuard.checkCompliance(msg.sender, bytes32(0), assets);
        lastDepositTime[receiver] = block.timestamp;
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        updateSnapshot
        returns (uint256)
    {
        if (block.timestamp < lastDepositTime[owner] + DEPOSIT_LOCK_TIME) {
            revert WithdrawalLocked(lastDepositTime[owner] + DEPOSIT_LOCK_TIME);
        }
        _updateWithdrawalLimit(assets);
        _ensureLiquidity(assets);
        uint256 _r1 = super.withdraw(assets, receiver, owner);
        withdrawnThisPeriod[block.timestamp / 1 days] += assets;
        return _r1;
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        updateSnapshot
        returns (uint256)
    {
        if (block.timestamp < lastDepositTime[owner] + DEPOSIT_LOCK_TIME) {
            revert WithdrawalLocked(lastDepositTime[owner] + DEPOSIT_LOCK_TIME);
        }
        uint256 assets = previewRedeem(shares);
        _updateWithdrawalLimit(assets);
        _ensureLiquidity(assets);
        uint256 _r2 = super.redeem(shares, receiver, owner);
        withdrawnThisPeriod[block.timestamp / 1 days] += previewRedeem(shares);
        return _r2;
    }

    function bridgeDeposit(uint256 assets, address receiver)
        external
        onlyRole(BRIDGE_ROLE)
        nonReentrant
        updateSnapshot
        returns (uint256 shares)
    {
        require(receiver != address(0), "HalalVault: invalid receiver");
        require(assets > 0, "HalalVault: zero assets");

        if (totalSupply() == 0 && assets < MIN_FIRST_DEPOSIT) {
            revert FirstDepositTooSmall(MIN_FIRST_DEPOSIT);
        }

        shariahGuard.checkCompliance(receiver, bytes32(0), assets);

        uint256 totalBefore = totalAssets();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        shares = _convertToShares(assets, Math.Rounding.Down);
        _mint(receiver, shares);

        lastDepositTime[receiver] = block.timestamp;

        emit BridgeDeposit(msg.sender, receiver, assets, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function _updateWithdrawalLimit(uint256 assets) internal {
        uint256 period = block.timestamp / 1 days;
        uint256 tvl = tvlSnapshot[period] != 0 ? tvlSnapshot[period] : totalAssets();
        uint256 limit = (tvl * MAX_WITHDRAWAL_PERCENT) / 10000;
        uint256 newUsed = withdrawnThisPeriod[period] + assets;

        if (newUsed > limit) {
            revert WithdrawalLimitExceeded(
                assets,
                limit > withdrawnThisPeriod[period]
                    ? limit - withdrawnThisPeriod[period]
                    : 0
            );
        }
        // recording moved to after super call
    }

    function _ensureLiquidity(uint256 assetsNeeded) internal {
        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));
        if (assetsNeeded <= idleBalance) return;

        uint256 deficit = assetsNeeded - idleBalance;
        require(address(strategyRouter) != address(0), "HalalVault: no strategy router");
        uint256 withdrawn = strategyRouter.withdrawFromStrategies(deficit);
        require(withdrawn >= deficit, "HalalVault: insufficient strategy liquidity");
        uint256 newBalance = IERC20(asset()).balanceOf(address(this));
        if (newBalance < assetsNeeded) {
            revert InsufficientLiquidity(assetsNeeded, newBalance);
        }
    }

    function setShariahGuard(address _newGuard) external onlyRole(MANAGER_ROLE) {
        if (_newGuard == address(0)) revert ZeroAddress("shariahGuard");
        shariahGuard = ShariahGuard(_newGuard);
        emit ShariahGuardUpdated(_newGuard);
    }

    function setStrategyRouter(address _router) external onlyRole(MANAGER_ROLE) {
        if (_router == address(0)) revert ZeroAddress("strategyRouter");
        strategyRouter = StrategyRouter(_router);
        emit StrategyRouterUpdated(_router);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(MANAGER_ROLE) { _unpause(); }
}