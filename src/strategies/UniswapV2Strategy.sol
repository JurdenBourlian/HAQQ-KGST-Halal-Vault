// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IFeeDistributor.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Used for fee-on-transfer tokens (PAXG, USDT, etc.)
    /// Does not return amounts — checks balance diff instead.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256);
}

contract UniswapV2Strategy is IStrategy, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant PERFORMANCE_FEE_BPS = 2000;
    uint256 public constant HARVEST_COOLDOWN = 1 days;
    uint256 public constant MAX_IL_BPS = 2000;
    uint256 public constant TWAP_PERIOD = 30 minutes;
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 100;
    uint256 public constant SWAP_DEADLINE = 30 seconds;

    IERC20 public immutable asset;
    IERC20 public immutable otherToken;
    IUniswapV2Pair public immutable pair;
    IUniswapV2Router02 public immutable router;
    IFeeDistributor public immutable feeDistributor;

    uint8 private immutable _decimalsAsset;
    uint8 private immutable _decimalsOther;

    /// @notice Set to true if otherToken charges a fee on transfer (e.g. PAXG).
    /// When true, swaps use swapExactTokensForTokensSupportingFeeOnTransferTokens
    /// and deposit measures actual received balance instead of nominal amount.
    bool public immutable otherTokenFeeOnTransfer;

    uint256 public totalLpHeld;
    uint256 public totalDepositedKgst;
    uint256 public harvestedProfit;
    uint256 public slippageBps = 50;
    uint256 public lastHarvest;
    uint256 public priceCumulativeLast;
    uint256 public blockTimestampLast;
    uint256 public twapPrice;
    bool public twapInitialized;

    error ExcessiveImpermanentLoss(uint256 currentValue, uint256 deposited);
    error PriceDeviationTooHigh(uint256 twapPrice, uint256 spotPrice);

    event Deposited(uint256 kgstIn, uint256 otherIn, uint256 lpReceived);
    event Withdrawn(uint256 lpBurned, uint256 kgstReturned, uint256 feePaid);
    event Harvested(uint256 profit, uint256 feePaid);
    event EmergencyWithdrawn(uint256 kgstOut, uint256 otherOut);
    event SlippageUpdated(uint256 newBps);
    event TwapUpdated(uint256 newTwapPrice);

    constructor(
        address _asset,
        address _otherToken,
        address _pair,
        address _router,
        address _feeDistributor,
        bool _otherTokenFeeOnTransfer
    ) {
        require(_asset != address(0), "V2Strategy: zero asset");
        require(_otherToken != address(0), "V2Strategy: zero otherToken");
        require(_pair != address(0), "V2Strategy: zero pair");
        require(_router != address(0), "V2Strategy: zero router");
        require(_feeDistributor != address(0), "V2Strategy: zero feeDistributor");
        require(_asset != _otherToken, "V2Strategy: identical tokens");

        asset = IERC20(_asset);
        otherToken = IERC20(_otherToken);
        pair = IUniswapV2Pair(_pair);
        router = IUniswapV2Router02(_router);
        feeDistributor = IFeeDistributor(_feeDistributor);
        otherTokenFeeOnTransfer = _otherTokenFeeOnTransfer;

        _decimalsAsset = IERC20Metadata(_asset).decimals();
        _decimalsOther = IERC20Metadata(_otherToken).decimals();

        require(
            (IUniswapV2Pair(_pair).token0() == _asset || IUniswapV2Pair(_pair).token1() == _asset) &&
            (IUniswapV2Pair(_pair).token0() == _otherToken || IUniswapV2Pair(_pair).token1() == _otherToken),
            "V2Strategy: pair tokens mismatch"
        );

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VAULT_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);

        lastHarvest = block.timestamp;
        
        asset.approve(address(router), type(uint256).max);
        otherToken.approve(address(router), type(uint256).max);
        IERC20(address(pair)).approve(address(router), type(uint256).max);
        asset.approve(address(feeDistributor), type(uint256).max);
        
        _updateTwap();
    }

    function deposit(uint256 kgstAmount)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        require(kgstAmount > 0, "V2Strategy: zero amount");
        require(twapInitialized, "V2Strategy: TWAP not initialized");
        asset.safeTransferFrom(msg.sender, address(this), kgstAmount);

        uint256 half = kgstAmount / 2;
        _swapKgstForOther(half);

        uint256 kgstBalance = asset.balanceOf(address(this));
        // For fee-on-transfer otherToken: measure actual balance, not nominal swap output
        uint256 otherBalance = otherToken.balanceOf(address(this));

        (uint256 kgstUsed, uint256 otherUsed, uint256 lpReceived) =
            _addLiquidity(kgstBalance, otherBalance);

        require(lpReceived > 0, "V2Strategy: no LP minted");
        totalLpHeld += lpReceived;
        totalDepositedKgst += kgstAmount;
        shares = lpReceived;

        uint256 kgstDust = kgstBalance - kgstUsed;
        uint256 otherDust = otherBalance - otherUsed;
        if (kgstDust > 0) asset.safeTransfer(msg.sender, kgstDust);
        if (otherDust > 0) otherToken.safeTransfer(msg.sender, otherDust);

        _updateTwap();
        emit Deposited(kgstUsed, otherUsed, lpReceived);
    }

    function withdraw(uint256 lpShares)
        external
        override
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        require(lpShares > 0, "V2Strategy: zero shares");
        require(lpShares <= totalLpHeld, "V2Strategy: insufficient LP");

        uint256 costBasis = totalLpHeld > 0
            ? (lpShares * totalDepositedKgst) / totalLpHeld
            : totalDepositedKgst;

        (uint256 kgstOut, uint256 otherOut) = _removeLiquidity(lpShares);

        if (otherOut > 0) _swapOtherForKgst(otherOut);

        uint256 totalKgst = asset.balanceOf(address(this));
        require(totalKgst > 0, "V2Strategy: nothing to return");

        uint256 profit = totalKgst > costBasis ? totalKgst - costBasis : 0;
        uint256 fee = (profit * PERFORMANCE_FEE_BPS) / 10000;

        totalLpHeld -= lpShares;
        totalDepositedKgst = totalLpHeld == 0 ? 0 : totalDepositedKgst - costBasis;

        if (fee > 0 && fee <= totalKgst) {
            feeDistributor.receiveFee(address(asset), fee);
        }

        amount = totalKgst - fee;
        asset.safeTransfer(msg.sender, amount);

        _updateTwap();
        emit Withdrawn(lpShares, amount, fee);
    }

    function totalValue() public view override returns (uint256) {
        return _totalValueInternal();
    }

    function _totalValueInternal() internal view returns (uint256) {
        (uint256 reserveKgst, uint256 reserveOther) = _getReserves();
        uint256 lpSupply = pair.totalSupply();
        uint256 fromLp;

        if (lpSupply > 0 && totalLpHeld > 0) {
            uint256 lpKgst = (totalLpHeld * reserveKgst) / lpSupply;
            uint256 lpOther = (totalLpHeld * reserveOther) / lpSupply;
            fromLp = lpKgst + _otherToKgst(lpOther, reserveKgst, reserveOther);
        }

        uint256 freeKgst = asset.balanceOf(address(this));
        uint256 freeOther = otherToken.balanceOf(address(this));
        uint256 fromFree = freeKgst + _otherToKgst(freeOther, reserveKgst, reserveOther);

        return fromLp + fromFree;
    }

    function checkImpermanentLoss() public view returns (bool) {
        if (totalDepositedKgst == 0) return true;
        uint256 currentValue = _totalValueInternal();
        return (currentValue * 10000) >= (totalDepositedKgst * (10000 - MAX_IL_BPS));
    }

    function _updateTwap() internal {
        (uint112 reserve0, uint112 reserve1, uint32 poolLastTs) = pair.getReserves();
        uint32 currentTime = uint32(block.timestamp);
        uint256 price0Cumulative = pair.price0CumulativeLast();
        uint256 price1Cumulative = pair.price1CumulativeLast();
        uint32 poolElapsed = currentTime - poolLastTs;

        if (poolElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            price0Cumulative += uint256(uint224((uint256(reserve1) << 112) / reserve0)) * poolElapsed;
            price1Cumulative += uint256(uint224((uint256(reserve0) << 112) / reserve1)) * poolElapsed;
        }

        uint32 timeElapsed = currentTime - uint32(blockTimestampLast);
        if (timeElapsed >= TWAP_PERIOD && blockTimestampLast != 0) {
            uint256 raw = pair.token0() == address(asset)
                ? (price0Cumulative - priceCumulativeLast) / timeElapsed
                : (price1Cumulative - priceCumulativeLast) / timeElapsed;
            twapPrice = raw;
            twapInitialized = true;
            emit TwapUpdated(twapPrice);
        }

        priceCumulativeLast = pair.token0() == address(asset)
            ? price0Cumulative
            : price1Cumulative;
        blockTimestampLast = currentTime;
    }

    function _checkPriceDeviation() internal view {
        if (twapPrice == 0) return;

        (uint256 reserveKgst, uint256 reserveOther) = _getReserves();
        if (reserveOther == 0) return;

        uint256 spotPrice = (reserveOther << 112) / reserveKgst;
        uint256 deviation = spotPrice > twapPrice
            ? ((spotPrice - twapPrice) * 10000) / twapPrice
            : ((twapPrice - spotPrice) * 10000) / twapPrice;

        if (deviation > MAX_PRICE_DEVIATION_BPS) {
            revert PriceDeviationTooHigh(twapPrice, spotPrice);
        }
    }

    function harvest() external onlyRole(KEEPER_ROLE) nonReentrant {
        require(block.timestamp >= lastHarvest + HARVEST_COOLDOWN, "V2Strategy: cooldown");
        require(checkImpermanentLoss(), "V2Strategy: excessive IL");
        _checkPriceDeviation();
        _harvest();
    }

    function initializeTwap() external onlyRole(MANAGER_ROLE) {
        _updateTwap();
    }

    function forceHarvest() external onlyRole(MANAGER_ROLE) nonReentrant {
        require(checkImpermanentLoss(), "V2Strategy: excessive IL");
        _harvest();
        lastHarvest = block.timestamp;
    }

    function _harvest() internal {
        uint256 currentValue = _totalValueInternal();
        uint256 basis = totalDepositedKgst + harvestedProfit;
        if (currentValue <= basis) {
            lastHarvest = block.timestamp;
            return;
        }

        uint256 profit = currentValue - basis;
        uint256 fee = (profit * PERFORMANCE_FEE_BPS) / 10000;
        if (fee == 0) {
            lastHarvest = block.timestamp;
            return;
        }

        _withdrawForAmount(fee);
        uint256 available = asset.balanceOf(address(this));
        uint256 toSend = fee > available ? available : fee;
        if (toSend > 0) {
            feeDistributor.receiveFee(address(asset), toSend);
            uint256 actualProfit = fee > 0 ? (toSend * profit) / fee : 0;
            harvestedProfit += actualProfit;
        }

        lastHarvest = block.timestamp;
        _updateTwap();
        emit Harvested(profit, toSend);
    }

    function pendingProfit() external view returns (uint256) {
        uint256 currentValue = _totalValueInternal();
        uint256 basis = totalDepositedKgst + harvestedProfit;
        return currentValue > basis ? currentValue - basis : 0;
    }

    function emergencyWithdraw(uint256 amount)
        external
        override
        onlyRole(MANAGER_ROLE)
        nonReentrant
    {
        if (totalLpHeld > 0) {
            (uint256 kgstOut, uint256 otherOut) = _removeLiquidity(totalLpHeld);
            totalLpHeld = 0;
            if (otherOut > 0) _swapOtherForKgst(otherOut);
            emit EmergencyWithdrawn(kgstOut, otherOut);
        }

        uint256 kgstBalance = asset.balanceOf(address(this));
        if (kgstBalance == 0) return;

        uint256 toSend = amount < kgstBalance ? amount : kgstBalance;
        totalDepositedKgst = 0;
        harvestedProfit = 0;
        asset.safeTransfer(msg.sender, toSend);
    }

    function setSlippage(uint256 _bps) external onlyRole(MANAGER_ROLE) {
        require(_bps <= 500, "V2Strategy: slippage > 5%");
        slippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    function _withdrawForAmount(uint256 needed) internal {
        uint256 free = asset.balanceOf(address(this));
        if (free >= needed) return;

        uint256 require_ = needed - free;
        (uint256 reserveKgst, ) = _getReserves();
        uint256 lpSupply = pair.totalSupply();
        uint256 lpNeeded = lpSupply > 0 && reserveKgst > 0
            ? (require_ * lpSupply * 2) / reserveKgst
            : totalLpHeld;

        if (lpNeeded > totalLpHeld) lpNeeded = totalLpHeld;
        if (lpNeeded == 0) return;

        uint256 costBasis = totalLpHeld > 0
            ? (lpNeeded * totalDepositedKgst) / totalLpHeld
            : 0;

        (, uint256 otherOut) = _removeLiquidity(lpNeeded);
        totalLpHeld -= lpNeeded;
        totalDepositedKgst = totalLpHeld == 0 ? 0 : (totalDepositedKgst > costBasis ? totalDepositedKgst - costBasis : 0);
        if (otherOut > 0) _swapOtherForKgst(otherOut);
    }

    function _swapKgstForOther(uint256 kgstAmount) internal {
        if (kgstAmount == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(asset);
        path[1] = address(otherToken);

        uint256 amountOutMin = _applySlippage(_quote(kgstAmount, true));

        if (otherTokenFeeOnTransfer) {
            // otherToken charges fee on transfer — use supporting variant.
            // Output amount is unknown upfront; caller should use balanceOf diff.
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                kgstAmount,
                amountOutMin,
                path,
                address(this),
                block.timestamp + SWAP_DEADLINE
            );
        } else {
            router.swapExactTokensForTokens(
                kgstAmount,
                amountOutMin,
                path,
                address(this),
                block.timestamp + SWAP_DEADLINE
            );
        }
    }

    function _swapOtherForKgst(uint256 otherAmount) internal {
        if (otherAmount == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(otherToken);
        path[1] = address(asset);

        uint256 amountOutMin = _applySlippage(_quote(otherAmount, false));

        if (otherTokenFeeOnTransfer) {
            // otherToken charges fee when leaving wallet — use supporting variant.
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                otherAmount,
                amountOutMin,
                path,
                address(this),
                block.timestamp + SWAP_DEADLINE
            );
        } else {
            router.swapExactTokensForTokens(
                otherAmount,
                amountOutMin,
                path,
                address(this),
                block.timestamp + SWAP_DEADLINE
            );
        }
    }

    function _addLiquidity(uint256 kgstAmount, uint256 otherAmount)
        internal
        returns (uint256 kgstUsed, uint256 otherUsed, uint256 liquidity)
    {
        (kgstUsed, otherUsed, liquidity) = router.addLiquidity(
            address(asset),
            address(otherToken),
            kgstAmount,
            otherAmount,
            _applySlippage(kgstAmount),
            _applySlippage(otherAmount),
            address(this),
            block.timestamp + SWAP_DEADLINE
        );
    }

    function _removeLiquidity(uint256 lpAmount)
        internal
        returns (uint256 kgstOut, uint256 otherOut)
    {
        (uint256 expKgst, uint256 expOther) = _expectedOutputs(lpAmount);

        (kgstOut, otherOut) = router.removeLiquidity(
            address(asset),
            address(otherToken),
            lpAmount,
            _applySlippage(expKgst),
            _applySlippage(expOther),
            address(this),
            block.timestamp + SWAP_DEADLINE
        );
    }

    function _getReserves() internal view returns (uint256 reserveKgst, uint256 reserveOther) {
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        if (pair.token0() == address(asset)) {
            (reserveKgst, reserveOther) = (uint256(r0), uint256(r1));
        } else {
            (reserveKgst, reserveOther) = (uint256(r1), uint256(r0));
        }
    }

    function _expectedOutputs(uint256 lpShares)
        internal
        view
        returns (uint256 expKgst, uint256 expOther)
    {
        uint256 lpSupply = pair.totalSupply();
        if (lpSupply == 0) return (0, 0);

        (uint256 rKgst, uint256 rOther) = _getReserves();
        expKgst = (lpShares * rKgst) / lpSupply;
        expOther = (lpShares * rOther) / lpSupply;
    }

    function _quote(uint256 amountIn, bool kgstToOther) internal view returns (uint256) {
        (uint256 rKgst, uint256 rOther) = _getReserves();
        if (rKgst == 0 || rOther == 0) return 0;

        uint256 rIn = kgstToOther ? rKgst : rOther;
        uint256 rOut = kgstToOther ? rOther : rKgst;
        return (amountIn * rOut) / (rIn + amountIn);
    }

    function _otherToKgst(
        uint256 otherAmount,
        uint256 reserveKgst,
        uint256 reserveOther
    ) internal view returns (uint256) {
        if (reserveOther == 0 || otherAmount == 0) return 0;

        uint256 normalised = otherAmount;
        if (_decimalsOther < _decimalsAsset) {
            normalised = otherAmount * (10 ** uint256(_decimalsAsset - _decimalsOther));
        } else if (_decimalsOther > _decimalsAsset) {
            normalised = otherAmount / (10 ** uint256(_decimalsOther - _decimalsAsset));
        }

        uint256 normReserveOther = reserveOther;
        if (_decimalsOther < _decimalsAsset) {
            normReserveOther = reserveOther * (10 ** uint256(_decimalsAsset - _decimalsOther));
        } else if (_decimalsOther > _decimalsAsset) {
            normReserveOther = reserveOther / (10 ** uint256(_decimalsOther - _decimalsAsset));
        }

        if (normReserveOther == 0) return 0;
        return (normalised * reserveKgst) / normReserveOther;
    }

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return (amount * (10000 - slippageBps)) / 10000;
    }
}
