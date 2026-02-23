// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IShariahOracle.sol";

contract MockShariahOracle is IShariahOracle {
    bool public immutable isCompliantResult;
    string public statusStr;
    uint256 public immutable lastUpdatedTimestamp;

    constructor(bool _isCompliant) {
        isCompliantResult = _isCompliant;
        statusStr = _isCompliant ? "compliant" : "non-compliant";
        lastUpdatedTimestamp = block.timestamp;
    }

    function isCompliant(address, uint256) external view override returns (bool) {
        return isCompliantResult;
    }

    function complianceStatus(address) external view override returns (string memory) {
        return statusStr;
    }

    function lastUpdated() external view override returns (uint256) {
        return lastUpdatedTimestamp;
    }
}