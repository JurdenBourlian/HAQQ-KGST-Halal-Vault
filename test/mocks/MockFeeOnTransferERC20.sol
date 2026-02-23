// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simulates a fee-on-transfer token like PAXG (0.02% fee per transfer).
/// Used in tests to verify UniswapV2Strategy handles fee-on-transfer correctly.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 2; // 0.02% like PAXG

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            // mint/burn — no fee
            super._transfer(from, to, amount);
            return;
        }
        uint256 fee = (amount * FEE_BPS) / 10000;
        uint256 net = amount - fee;
        // Fee goes to address(1) — a burn-like sink for testing
        super._transfer(from, address(1), fee);
        super._transfer(from, to, net);
    }
}
