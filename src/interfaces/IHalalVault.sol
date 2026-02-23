// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IHalalVault is IERC4626 {
    function bridgeDeposit(uint256 assets, address receiver) external returns (uint256 shares);
    function depositWithRegion(uint256 assets, address receiver, bytes32 regionId) external returns (uint256 shares);
    function setStrategyRouter(address router) external;
    function strategyRouter() external view returns (address);
    function shariahGuard() external view returns (address);
}