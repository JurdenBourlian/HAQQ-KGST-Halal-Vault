
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IStrategy.sol";

contract StrategyRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant MAX_STRATEGIES = 20;
    uint256 public constant MAX_STRATEGIES_PER_WITHDRAW = 10;
    uint256 public constant MIN_WITHDRAW_AMOUNT = 1e15;

    struct StrategyInfo {
        IStrategy strategy;
        uint256 targetBps;
        bool active;
        bool paused;
    }

    IERC20 public immutable kgsToken;
    address public immutable vault;

    StrategyInfo[] public strategies;

    event StrategyAdded(address indexed strategy, uint256 targetBps);
    event StrategyDeactivated(address indexed strategy);
    event StrategyReactivated(address indexed strategy, uint256 newTargetBps);
    event StrategyPaused(address indexed strategy, bool paused);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    error StrategyAlreadyExists(address strategy);
    error TotalBpsExceeds100Percent(uint256 total);
    error IndexOutOfBounds(uint256 index, uint256 length);
    error InsufficientStrategyLiquidity(uint256 requested, uint256 available);
    error OnlyVault();
    error BpsMustBeRedistributed(uint256 bps);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address _kgsToken, address _vault) {
        require(_kgsToken != address(0), "StrategyRouter: zero token");
        require(_vault != address(0), "StrategyRouter: zero vault");
        kgsToken = IERC20(_kgsToken);
        vault = _vault;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function addStrategy(address _strategy, uint256 _targetBps)
        external
        onlyRole(MANAGER_ROLE)
    {
        require(_strategy != address(0), "StrategyRouter: zero strategy");
        require(_targetBps <= 10000, "StrategyRouter: BPS > 100%");
        require(strategies.length < MAX_STRATEGIES, "StrategyRouter: max strategies reached");

        for (uint256 i = 0; i < strategies.length; i++) {
            if (address(strategies[i].strategy) == _strategy && strategies[i].active) {
                revert StrategyAlreadyExists(_strategy);
            }
        }

        uint256 newTotal = totalTargetBps() + _targetBps;
        if (newTotal > 10000) revert TotalBpsExceeds100Percent(newTotal);

        strategies.push(StrategyInfo({
            strategy: IStrategy(_strategy),
            targetBps: _targetBps,
            active: true,
            paused: false
        }));

        emit StrategyAdded(_strategy, _targetBps);
    }

    function deactivateStrategy(uint256 index, uint256 redistributeToIndex)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (index >= strategies.length) revert IndexOutOfBounds(index, strategies.length);
        require(strategies[index].active, "StrategyRouter: already inactive");

        uint256 freedBps = strategies[index].targetBps;
        strategies[index].active = false;
        strategies[index].targetBps = 0;

        if (redistributeToIndex != type(uint256).max) {
            if (redistributeToIndex >= strategies.length)
                revert IndexOutOfBounds(redistributeToIndex, strategies.length);
            require(strategies[redistributeToIndex].active, "StrategyRouter: target inactive");
            uint256 newBps = strategies[redistributeToIndex].targetBps + freedBps;
            require(newBps <= 10000, "StrategyRouter: BPS overflow");
            strategies[redistributeToIndex].targetBps = newBps;
        }

        emit StrategyDeactivated(address(strategies[index].strategy));
    }

    function reactivateStrategy(uint256 index, uint256 newTargetBps)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (index >= strategies.length) revert IndexOutOfBounds(index, strategies.length);
        require(!strategies[index].active, "StrategyRouter: already active");
        require(newTargetBps <= 10000, "StrategyRouter: BPS > 100%");

        uint256 newTotal = totalTargetBps() + newTargetBps;
        if (newTotal > 10000) revert TotalBpsExceeds100Percent(newTotal);

        strategies[index].active = true;
        strategies[index].targetBps = newTargetBps;

        emit StrategyReactivated(address(strategies[index].strategy), newTargetBps);
    }

    function pauseStrategy(uint256 index, bool _paused)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        if (index >= strategies.length) revert IndexOutOfBounds(index, strategies.length);
        strategies[index].paused = _paused;
        emit StrategyPaused(address(strategies[index].strategy), _paused);
    }

    function totalTargetBps() public view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active && !strategies[i].paused) {
                total += strategies[i].targetBps;
            }
        }
    }

    function totalValue() public view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active && !strategies[i].paused) {
                try strategies[i].strategy.totalValue() returns (uint256 v) {
                    total += v;
                } catch {
                    continue;
                }
            }
        }
    }

    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function getStrategyInfo(uint256 index) external view returns (
        address strategy,
        uint256 targetBps,
        bool active,
        bool paused,
        uint256 currentValue
    ) {
        if (index >= strategies.length) revert IndexOutOfBounds(index, strategies.length);
        StrategyInfo memory info = strategies[index];
        uint256 val = 0;
        try info.strategy.totalValue() returns (uint256 v) {
            val = v;
        } catch {
            val = 0;
        }
        return (address(info.strategy), info.targetBps, info.active, info.paused, val);
    }

    function withdrawFromStrategies(uint256 amount)
        external
        onlyVault
        nonReentrant
        returns (uint256 withdrawn)
    {
        require(amount > 0, "StrategyRouter: zero amount");
        uint256 n = strategies.length;
        uint256 totalStrategyValue = totalValue();
        if (totalStrategyValue == 0) return 0;

        uint256 remaining = amount;
        uint256[] memory strategyBalance = new uint256[](n);
        uint256[] memory strategyWithdrawn = new uint256[](n);
        uint256 processedCount = 0;

        for (uint256 i = 0; i < n; i++) {
            if (!strategies[i].active || strategies[i].paused) continue;
            try strategies[i].strategy.totalValue() returns (uint256 v) {
                strategyBalance[i] = v;
            } catch {
                strategyBalance[i] = 0;
            }
        }

        // FIX: capture returns (uint256) in try blocks so Solidity ABI-decodes
        // the return value correctly. Without this, the compiler may generate
        // return-data validation that causes silent reverts inside the try body.
        for (uint256 i = 0; i < n && remaining > 0 && processedCount < MAX_STRATEGIES_PER_WITHDRAW; i++) {
            if (!strategies[i].active || strategies[i].paused) continue;
            if (strategyBalance[i] == 0) continue;

            uint256 toWithdraw = (amount * strategyBalance[i] + totalStrategyValue - 1) / totalStrategyValue;
            if (toWithdraw < MIN_WITHDRAW_AMOUNT) continue;
            if (toWithdraw > remaining) toWithdraw = remaining;
            if (toWithdraw > strategyBalance[i]) toWithdraw = strategyBalance[i];

            if (toWithdraw > 0) {
                uint256 balBefore = kgsToken.balanceOf(address(this));
                try strategies[i].strategy.withdraw(toWithdraw) returns (uint256) {
                    uint256 actualReceived = kgsToken.balanceOf(address(this)) - balBefore;
                    withdrawn += actualReceived;
                    remaining = remaining > actualReceived ? remaining - actualReceived : 0;
                    strategyWithdrawn[i] += actualReceived;
                    processedCount++;
                } catch {
                    continue;
                }
            }
        }

        if (remaining > 0) {
            for (uint256 i = 0; i < n && remaining > 0 && processedCount < MAX_STRATEGIES_PER_WITHDRAW; i++) {
                if (!strategies[i].active || strategies[i].paused) continue;
                uint256 available = strategyBalance[i] > strategyWithdrawn[i]
                    ? strategyBalance[i] - strategyWithdrawn[i]
                    : 0;
                if (available == 0) continue;

                uint256 toWithdraw = available > remaining ? remaining : available;
                if (toWithdraw < MIN_WITHDRAW_AMOUNT && remaining >= MIN_WITHDRAW_AMOUNT) continue;

                uint256 balBefore = kgsToken.balanceOf(address(this));
                try strategies[i].strategy.withdraw(toWithdraw) returns (uint256) {
                    uint256 actualReceived = kgsToken.balanceOf(address(this)) - balBefore;
                    withdrawn += actualReceived;
                    remaining = remaining > actualReceived ? remaining - actualReceived : 0;
                    strategyWithdrawn[i] += actualReceived;
                    processedCount++;
                } catch {
                    continue;
                }
            }
        }

        if (withdrawn == 0) {
            revert InsufficientStrategyLiquidity(amount, 0);
        }

        if (withdrawn > 0) {
            kgsToken.safeTransfer(msg.sender, withdrawn);
        }

        emit FundsWithdrawn(msg.sender, withdrawn);
        return withdrawn;
    }
}
