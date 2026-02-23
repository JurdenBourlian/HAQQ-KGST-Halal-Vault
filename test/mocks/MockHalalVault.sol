// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MockERC20.sol";

contract MockHalalVault is ERC20 {
    MockERC20 public immutable assetToken;

    constructor(MockERC20 _asset) ERC20("Mock hvKGST", "mhvKGST") {
        assetToken = _asset;
    }

    function bridgeDeposit(uint256 assets, address receiver) external returns (uint256 shares) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, assets);
        return assets;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }
}