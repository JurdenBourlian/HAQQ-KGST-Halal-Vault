// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract FeeDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant STRATEGY_ROLE = keccak256("STRATEGY_ROLE");

    struct Recipient {
        address account;
        uint256 shareBps;
    }

    IERC20 public immutable feeToken;

    /// @notice Founder address — set once at deployment, never changeable.
    /// @dev Receives FOUNDER_SHARE_BPS from every distribution, always.
    address public immutable founder;

    /// @notice Founder's permanent share: 2000 bps = 20%.
    /// @dev Remaining 8000 bps (80%) are split among configurable recipients.
    uint256 public constant FOUNDER_SHARE_BPS = 2000;
    uint256 public constant RECIPIENTS_TOTAL_BPS = 10000 - FOUNDER_SHARE_BPS; // 8000

    Recipient[] public recipients;
    mapping(address => uint256) public pendingFees;

    event FeesReceived(address indexed from, uint256 amount);
    event FeesDistributed(uint256 totalAmount, uint256 founderShare, uint256 timestamp);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event RecipientsUpdated(uint256 count);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroFounderAddress();
    error ZeroTokenAddress();

    constructor(address _feeToken, address _founder) {
        if (_feeToken == address(0)) revert ZeroTokenAddress();
        if (_founder == address(0)) revert ZeroFounderAddress();
        feeToken = IERC20(_feeToken);
        founder = _founder;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
    }

    function receiveFee(address token, uint256 amount)
        external
        onlyRole(STRATEGY_ROLE)
    {
        require(token == address(feeToken), "FeeDistributor: wrong token");
        require(amount > 0, "FeeDistributor: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FeesReceived(msg.sender, amount);
    }

    function distribute() external onlyRole(FEE_MANAGER_ROLE) nonReentrant {
        uint256 balance = feeToken.balanceOf(address(this));
        require(balance > 0, "FeeDistributor: nothing to distribute");
        uint256 len = recipients.length;
        require(len > 0, "FeeDistributor: no recipients");

        // Founder always gets their immutable share first — no exceptions.
        uint256 founderShare = (balance * FOUNDER_SHARE_BPS) / 10000;
        if (founderShare > 0) {
            pendingFees[founder] += founderShare;
        }

        // Remaining 80% split among configurable recipients.
        // Each recipient's shareBps is expressed as a fraction of RECIPIENTS_TOTAL_BPS (8000).
        uint256 remainder = balance - founderShare;
        for (uint256 i; i < len; ) {
            uint256 share = (remainder * recipients[i].shareBps) / RECIPIENTS_TOTAL_BPS;
            if (share > 0) {
                pendingFees[recipients[i].account] += share;
            }
            unchecked { ++i; }
        }

        emit FeesDistributed(balance, founderShare, block.timestamp);
    }

    function claimFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        require(amount > 0, "FeeDistributor: no fees");
        pendingFees[msg.sender] = 0;
        feeToken.safeTransfer(msg.sender, amount);
        emit FeesClaimed(msg.sender, amount);
    }

    /// @notice Update the configurable recipient list.
    /// @dev Shares must sum to exactly RECIPIENTS_TOTAL_BPS (8000).
    ///      Founder cannot be added here — they already receive FOUNDER_SHARE_BPS permanently.
    function setRecipients(Recipient[] calldata _recipients)
        external
        onlyRole(FEE_MANAGER_ROLE)
    {
        delete recipients;
        uint256 totalBps;
        for (uint256 i; i < _recipients.length; ) {
            require(_recipients[i].account != address(0), "FeeDistributor: zero account");
            require(_recipients[i].account != founder, "FeeDistributor: founder has immutable share");
            recipients.push(_recipients[i]);
            totalBps += _recipients[i].shareBps;
            unchecked { ++i; }
        }
        require(totalBps == RECIPIENTS_TOTAL_BPS, "FeeDistributor: shares must sum to 8000 bps");
        emit RecipientsUpdated(_recipients.length);
    }

    function rescueToken(address token, uint256 amount, address to)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        require(token != address(feeToken), "FeeDistributor: cannot rescue fee token");
        require(to != address(0), "FeeDistributor: zero address");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function getRecipients() external view returns (Recipient[] memory) {
        return recipients;
    }

    /// @notice Returns the full distribution breakdown for the current balance.
    /// @dev Useful for frontend display and off-chain monitoring.
    function previewDistribution() external view returns (
        uint256 founderAmount,
        address[] memory accounts,
        uint256[] memory amounts
    ) {
        uint256 balance = feeToken.balanceOf(address(this));
        founderAmount = (balance * FOUNDER_SHARE_BPS) / 10000;
        uint256 remainder = balance - founderAmount;
        uint256 len = recipients.length;
        accounts = new address[](len);
        amounts = new uint256[](len);
        for (uint256 i; i < len; ) {
            accounts[i] = recipients[i].account;
            amounts[i] = (remainder * recipients[i].shareBps) / RECIPIENTS_TOTAL_BPS;
            unchecked { ++i; }
        }
    }
}
