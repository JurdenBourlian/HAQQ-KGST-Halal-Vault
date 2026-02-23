// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IStrategy.sol";

contract UniswapV3Strategy is IStrategy, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public immutable asset;
    address public immutable pool;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidityDeposited;
    uint256 public nftTokenId;

    event Deposited(uint256 amount, uint128 liquidity);
    event Withdrawn(uint256 shares, uint256 amountReturned);
    event RangeUpdated(int24 tickLower, int24 tickUpper);
    event EmergencyWithdrawn(uint256 amount);

    constructor(
        address _asset,
        address _pool,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        require(_asset != address(0), "V3Strategy: zero asset");
        require(_pool != address(0), "V3Strategy: zero pool");
        asset = IERC20(_asset);
        pool = _pool;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VAULT_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function deposit(uint256 amount)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        shares = amount;
        liquidityDeposited += uint128(amount);
        emit Deposited(amount, uint128(amount));
    }

    function withdraw(uint256 shares)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        require(uint128(shares) <= liquidityDeposited, "V3Strategy: insufficient liquidity");
        liquidityDeposited -= uint128(shares);
        amount = shares;
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(shares, amount);
    }

    function totalValue() external view override returns (uint256) {
        return uint256(liquidityDeposited);
    }

    function emergencyWithdraw(uint256 amount)
        external
        override
        onlyRole(MANAGER_ROLE)
        nonReentrant
    {
        require(
            asset.balanceOf(address(this)) >= amount,
            "V3Strategy: insufficient balance"
        );
        asset.safeTransfer(msg.sender, amount);
        emit EmergencyWithdrawn(amount);
    }

    function updateRange(int24 _tickLower, int24 _tickUpper)
        external
        onlyRole(MANAGER_ROLE)
    {
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        emit RangeUpdated(_tickLower, _tickUpper);
    }
}