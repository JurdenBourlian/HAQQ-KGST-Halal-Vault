// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AxelarExecutable} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutable.sol";
import {IAxelarGasService} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

import "./interfaces/IHalalVault.sol";

contract AxelarBridgeReceiver is AxelarExecutable, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant BRIDGE_ADMIN_ROLE = keccak256("BRIDGE_ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IAxelarGasService public immutable gasService;
    IERC20 public immutable kgsToken;
    IHalalVault public immutable vault;

    mapping(string => string) public trustedSources;

    uint256 public constant RATE_LIMIT_WINDOW = 1 hours;
    uint256 public rateLimitPerWindow;
    mapping(uint256 => uint256) public windowVolume;

    uint256 public userRateLimit;
    mapping(address => mapping(uint256 => uint256)) public userVolume;

    mapping(bytes32 => bool) public processedMessages;

    event BridgeReceived(
        string indexed sourceChain,
        address indexed recipient,
        uint256 amount,
        bool autoDeposit,
        uint64 nonce
    );
    event RateLimitUpdated(uint256 newGlobalLimit, uint256 newUserLimit);
    event TrustedSourceSet(string sourceChain, string sourceAddress);
    event MessageProcessed(bytes32 messageHash);

    error UnauthorizedSource(string chain, string sender);
    error RateLimitExceeded(uint256 requested, uint256 available);
    error UserRateLimitExceeded(address user, uint256 requested, uint256 available);
    error MessageAlreadyProcessed(bytes32 messageHash);
    error InvalidPayload();
    error BridgeDepositFailed();

    constructor(
        address _gateway,
        address _gasService,
        address _kgsToken,
        address _vault
    ) AxelarExecutable(_gateway) {
        require(_gateway != address(0), "BridgeReceiver: zero gateway");
        require(_gasService != address(0), "BridgeReceiver: zero gasService");
        require(_kgsToken != address(0), "BridgeReceiver: zero token");
        require(_vault != address(0), "BridgeReceiver: zero vault");

        gasService = IAxelarGasService(_gasService);
        kgsToken = IERC20(_kgsToken);
        vault = IHalalVault(_vault);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BRIDGE_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        rateLimitPerWindow = 100_000e18;
        userRateLimit = 10_000e18;
    }

    function _execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override nonReentrant whenNotPaused {
        _handleMessage(sourceChain, sourceAddress, payload);
    }

    function _handleMessage(
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal {
        string memory trustedSource = trustedSources[sourceChain];
        if (keccak256(bytes(trustedSource)) != keccak256(bytes(sourceAddress))) {
            revert UnauthorizedSource(sourceChain, sourceAddress);
        }

        if (payload.length < 4 * 32) revert InvalidPayload();

        (address recipient, uint256 amount, bool autoDeposit, uint64 nonce) =
            abi.decode(payload, (address, uint256, bool, uint64));

        require(recipient != address(0), "BridgeReceiver: invalid recipient");
        require(amount > 0, "BridgeReceiver: zero amount");

        bytes32 messageHash = keccak256(abi.encodePacked(
            sourceChain,
            sourceAddress,
            recipient,
            amount,
            autoDeposit,
            nonce,
            block.chainid,
            block.number
        ));

        if (processedMessages[messageHash]) {
            revert MessageAlreadyProcessed(messageHash);
        }
        processedMessages[messageHash] = true;

        _enforceRateLimits(recipient, amount);

        if (autoDeposit) {
            kgsToken.forceApprove(address(vault), amount);
            try vault.bridgeDeposit(amount, recipient) {
                kgsToken.forceApprove(address(vault), 0);
            } catch {
                kgsToken.forceApprove(address(vault), 0);
                revert BridgeDepositFailed();
            }
        } else {
            kgsToken.safeTransfer(recipient, amount);
        }

        emit BridgeReceived(sourceChain, recipient, amount, autoDeposit, nonce);
        emit MessageProcessed(messageHash);
    }

    function _enforceRateLimits(address user, uint256 amount) internal {
        if (rateLimitPerWindow == 0 && userRateLimit == 0) return;

        uint256 currentWindow = block.timestamp / RATE_LIMIT_WINDOW;

        if (rateLimitPerWindow > 0) {
            uint256 globalUsed = windowVolume[currentWindow] + amount;
            if (globalUsed > rateLimitPerWindow)
                revert RateLimitExceeded(amount, rateLimitPerWindow - windowVolume[currentWindow]);
            windowVolume[currentWindow] = globalUsed;
        }

        if (userRateLimit > 0) {
            uint256 userUsed = userVolume[user][currentWindow] + amount;
            if (userUsed > userRateLimit)
                revert UserRateLimitExceeded(user, amount, userRateLimit - userVolume[user][currentWindow]);
            userVolume[user][currentWindow] = userUsed;
        }
    }

    function setTrustedSource(
        string calldata sourceChain,
        string calldata sourceAddress
    ) external onlyRole(BRIDGE_ADMIN_ROLE) {
        require(bytes(sourceChain).length > 0, "BridgeReceiver: empty chain");
        require(bytes(sourceAddress).length >= 40, "BridgeReceiver: address too short");
        require(bytes(sourceAddress).length <= 64, "BridgeReceiver: address too long");
        trustedSources[sourceChain] = sourceAddress;
        emit TrustedSourceSet(sourceChain, sourceAddress);
    }

    function setRateLimits(uint256 _globalRate, uint256 _userRate)
        external
        onlyRole(BRIDGE_ADMIN_ROLE)
    {
        rateLimitPerWindow = _globalRate;
        userRateLimit = _userRate;
        emit RateLimitUpdated(_globalRate, _userRate);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(BRIDGE_ADMIN_ROLE) { _unpause(); }

    function getRateLimitStatus(address user) external view returns (
        uint256 globalUsed,
        uint256 globalLimit,
        uint256 userUsed,
        uint256 userLimit,
        uint256 remaining
    ) {
        uint256 currentWindow = block.timestamp / RATE_LIMIT_WINDOW;
        globalUsed = windowVolume[currentWindow];
        globalLimit = rateLimitPerWindow;
        userUsed = userVolume[user][currentWindow];
        userLimit = userRateLimit;
        remaining = globalLimit > globalUsed ? globalLimit - globalUsed : 0;
    }

    function exposed_execute(
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external {
        _execute(bytes32(0), sourceChain, sourceAddress, payload);
    }
}