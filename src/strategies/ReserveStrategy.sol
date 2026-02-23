// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IStrategy.sol";

contract ReserveStrategy is IStrategy, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public immutable asset;
    uint256 public reserveBalance;

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event EmergencyWithdrawn(uint256 amount);

    constructor(address _asset) {
        require(_asset != address(0), "ReserveStrategy: zero asset");
        asset = IERC20(_asset);
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
        reserveBalance += amount;
        shares = amount;
        emit Deposited(amount);
    }

    function withdraw(uint256 shares)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        require(shares <= reserveBalance, "ReserveStrategy: insufficient reserve");
        reserveBalance -= shares;
        amount = shares;
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(amount);
    }

    function totalValue() external view override returns (uint256) {
        return reserveBalance;
    }

    function emergencyWithdraw(uint256 amount)
        external
        override
        onlyRole(MANAGER_ROLE)
        nonReentrant
    {
        require(amount <= reserveBalance, "ReserveStrategy: exceeds reserve");
        reserveBalance -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit EmergencyWithdrawn(amount);
    }
}