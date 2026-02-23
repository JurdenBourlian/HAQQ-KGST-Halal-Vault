// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IShariahOracle {
    function isCompliant(address user, uint256 amount) external view returns (bool);
    function complianceStatus(address user) external view returns (string memory);
    function lastUpdated() external view returns (uint256);
}