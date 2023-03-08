// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/pools/IConicPool.sol";
import "../interfaces/pools/IRewardManager.sol";
import "../interfaces/ICurveHandler.sol";
import "../interfaces/tokenomics/IInflationManager.sol";
import "../interfaces/tokenomics/ILpTokenStaker.sol";
import "../interfaces/IConvexHandler.sol";
import "../interfaces/IController.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/vendor/IBaseRewardPool.sol";

import "./LpToken.sol";
import "./RewardManager.sol";

import "../libraries/ScaledMath.sol";
import "../libraries/ArrayExtensions.sol";

contract ConicPool is IConicPool, Ownable {
    using ArrayExtensions for uint256[];
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using SafeERC20 for IERC20;
    using SafeERC20 for ILpToken;
    using ScaledMath for uint256;
    using Address for address;

    // Avoid stack depth errors
    struct DepositVars {
        uint256 exchangeRate_;
        uint256 underlyingBalanceIncrease_;
        uint256 mintableUnderlyingAmount_;
        uint256 lpReceived;
    }

    /// @dev once the deviation gets under this threshold, the reward distribution will be paused
    /// until the next rebalancing. This is expressed as a ratio, scaled with 18 decimals
    /// 2% (maximum an OmniPool can deviate from the target balance)
    uint256 public constant MAX_DEVIATION = 0.02e18;
    uint256 internal constant _IDLE_RATIO_UPPER_BOUND = 0.2e18;
    uint256 internal constant _MIN_DEPEG_THRESHOLD = 0.01e18;
    uint256 internal constant _MAX_DEPEG_THRESHOLD = 0.1e18;
    uint256 internal constant _DEPEG_UNDERLYING_MULTIPLIER = 2;
    uint256 internal constant _TOTAL_UNDERLYING_CACHE_EXPIRY = 3 days;

    IERC20 public immutable CVX;
    IERC20 public immutable CRV;
    IERC20 public constant CNC = IERC20(0x9aE380F0272E2162340a5bB646c354271c0F5cFC);
    address internal constant _WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IERC20Metadata public immutable override underlying;
    ILpToken public immutable override lpToken;

    IRewardManager public immutable rewardManager;
    IController public immutable controller;
    ILpTokenStaker public immutable lpTokenStaker;

    uint256 public maxIdleCurveLpRatio = 0.05e18; // triggers Convex staking when exceeded
    bool public isShutdown;
    uint256 public depegThreshold = 0.03e18; // 3%
    uint256 internal _cacheUpdatedTimestamp;
    uint256 internal _cachedTotalUnderlying;

    /// @dev `true` while the reward distribution is active
    bool public rebalancingRewardActive;

    EnumerableSet.AddressSet internal _curvePools;
    EnumerableMap.AddressToUintMap internal weights; // liquidity allocation weights

    /// @dev the absolute value in terms of USD of the total deviation after
    /// the weights have been updated
    uint256 public totalDeviationAfterWeightUpdate;

    mapping(address => uint256) _cachedPrices;

    modifier onlyController() {
        require(msg.sender == address(controller), "not authorized");
        _;
    }

    constructor(
        address _underlying,
        address _controller,
        address locker,
        string memory _lpTokenName,
        string memory _symbol,
        address _cvx,
        address _crv,
        address _lpTokenStaker
    ) {
        underlying = IERC20Metadata(_underlying);
        controller = IController(_controller);
        uint8 decimals = IERC20Metadata(_underlying).decimals();
        lpToken = new LpToken(address(this), decimals, _lpTokenName, _symbol);
        lpTokenStaker = ILpTokenStaker(_lpTokenStaker);
        RewardManager _rewardManager = new RewardManager(
            _controller,
            address(this),
            address(lpToken),
            _underlying,
            _lpTokenStaker,
            locker
        );
        _rewardManager.transferOwnership(msg.sender);
        rewardManager = _rewardManager;

        CVX = IERC20(_cvx);
        CRV = IERC20(_crv);
        CVX.safeApprove(address(_rewardManager), type(uint256).max);
        CRV.safeApprove(address(_rewardManager), type(uint256).max);
        CNC.safeApprove(address(_rewardManager), type(uint256).max);
    }

    /// but we always delegate-call to the Curve handler, which means
    /// that we need to be able to receive the ETH to unwrap it and
    /// send it to the Curve pool, as well as to receive it back from
    /// the Curve pool when withdrawing
    receive() external payable {
        require(address(underlying) == _WETH_ADDRESS, "not WETH pool");
    }

    /// @notice Deposit underlying on behalf of someone
    /// @param underlyingAmount Amount of underlying to deposit
    /// @param minLpReceived The minimum amoun of LP to accept from the deposit
    /// @return lpReceived The amount of LP received
    function depositFor(
        address account,
        uint256 underlyingAmount,
        uint256 minLpReceived,
        bool stake
    ) public override returns (uint256) {
        DepositVars memory vars;

        // Preparing deposit
        require(!isShutdown, "pool is shutdown");
        require(underlyingAmount > 0, "deposit amount cannot be zero");
        (
            uint256 underlyingBalanceBefore_,
            uint256[] memory allocatedPerPoolBefore
        ) = _getTotalAndPerPoolUnderlying();
        vars.exchangeRate_ = _exchangeRate(underlyingBalanceBefore_);

        // Executing deposit
        IERC20 underlying_ = underlying;
        underlying_.safeTransferFrom(msg.sender, address(this), underlyingAmount);
        _depositToCurve(
            underlyingBalanceBefore_,
            allocatedPerPoolBefore,
            underlying_.balanceOf(address(this))
        );

        // Minting LP Tokens
        (
            uint256 underlyingBalanceAfter_,
            uint256[] memory allocatedPerPoolAfter
        ) = _getTotalAndPerPoolUnderlying();
        vars.underlyingBalanceIncrease_ = underlyingBalanceAfter_ - underlyingBalanceBefore_;
        vars.mintableUnderlyingAmount_ = _min(underlyingAmount, vars.underlyingBalanceIncrease_);
        vars.lpReceived = vars.mintableUnderlyingAmount_.divDown(vars.exchangeRate_);
        require(vars.lpReceived >= minLpReceived, "too much slippage");
        if (stake) {
            lpToken.mint(address(this), vars.lpReceived);
            lpToken.safeApprove(address(lpTokenStaker), vars.lpReceived);
            lpTokenStaker.stakeFor(vars.lpReceived, address(this), account);
        } else {
            lpToken.mint(account, vars.lpReceived);
        }

        if (rebalancingRewardActive) {
            _handleRebalancingRewards(
                account,
                underlyingBalanceBefore_,
                allocatedPerPoolBefore,
                underlyingBalanceAfter_,
                allocatedPerPoolAfter
            );
        }

        _cachedTotalUnderlying = underlyingBalanceAfter_;
        _cacheUpdatedTimestamp = block.timestamp;

        emit Deposit(msg.sender, underlyingAmount);
        return vars.lpReceived;
    }

    /// @notice Deposit underlying
    /// @param underlyingAmount Amount of underlying to deposit
    /// @param minLpReceived The minimum amoun of LP to accept from the deposit
    /// @return lpReceived The amount of LP received
    function deposit(uint256 underlyingAmount, uint256 minLpReceived)
        external
        override
        returns (uint256)
    {
        return depositFor(msg.sender, underlyingAmount, minLpReceived, true);
    }

    /// @notice Deposit underlying
    /// @param underlyingAmount Amount of underlying to deposit
    /// @param minLpReceived The minimum amoun of LP to accept from the deposit
    /// @param stake Whether or not to stake in the LpTokenStaker
    /// @return lpReceived The amount of LP received
    function deposit(
        uint256 underlyingAmount,
        uint256 minLpReceived,
        bool stake
    ) external override returns (uint256) {
        return depositFor(msg.sender, underlyingAmount, minLpReceived, stake);
    }

    function _depositToCurve(
        uint256 totalUnderlying_,
        uint256[] memory allocatedPerPool,
        uint256 underlyingAmount_
    ) internal {
        uint256 depositsRemaining_ = underlyingAmount_;
        uint256 totalAfterDeposit_ = totalUnderlying_ + underlyingAmount_;

        // NOTE: avoid modifying `allocatedPerPool`
        uint256[] memory allocatedPerPoolCopy = allocatedPerPool.copy();

        while (depositsRemaining_ > 0) {
            (uint256 curvePoolIndex_, uint256 maxDeposit_) = _getDepositPool(
                totalAfterDeposit_,
                allocatedPerPoolCopy
            );
            address curvePool_ = _curvePools.at(curvePoolIndex_);

            // Depositing into least balanced pool
            uint256 toDeposit_ = _min(depositsRemaining_, maxDeposit_);
            _depositToCurvePool(curvePool_, toDeposit_);
            depositsRemaining_ -= toDeposit_;
            allocatedPerPoolCopy[curvePoolIndex_] += toDeposit_;
        }
    }

    function _getDepositPool(uint256 totalUnderlying_, uint256[] memory allocatedPerPool)
        internal
        view
        returns (uint256 poolIndex, uint256 maxDepositAmount)
    {
        uint256 curvePoolCount_ = allocatedPerPool.length;
        int256 iPoolIndex = -1;
        for (uint256 i; i < curvePoolCount_; i++) {
            address curvePool_ = _curvePools.at(i);
            uint256 allocatedUnderlying_ = allocatedPerPool[i];
            uint256 targetAllocation_ = totalUnderlying_.mulDown(weights.get(curvePool_));
            if (allocatedUnderlying_ >= targetAllocation_) continue;
            uint256 maxBalance_ = targetAllocation_ + targetAllocation_.mulDown(MAX_DEVIATION);
            uint256 maxDepositAmount_ = maxBalance_ - allocatedUnderlying_;
            if (maxDepositAmount_ <= maxDepositAmount) continue;
            maxDepositAmount = maxDepositAmount_;
            iPoolIndex = int256(i);
        }
        require(iPoolIndex > -1, "error retrieving deposit pool");
        poolIndex = uint256(iPoolIndex);
    }

    function _depositToCurvePool(address curvePool_, uint256 underlyingAmount_) internal {
        if (underlyingAmount_ == 0) return;
        controller.curveHandler().functionDelegateCall(
            abi.encodeWithSignature(
                "deposit(address,address,uint256)",
                curvePool_,
                underlying,
                underlyingAmount_
            )
        );

        uint256 idleCurveLpBalance_ = _idleCurveLpBalance(curvePool_);
        uint256 totalCurveLpBalance_ = _stakedCurveLpBalance(curvePool_) + idleCurveLpBalance_;

        if (idleCurveLpBalance_.divDown(totalCurveLpBalance_) >= maxIdleCurveLpRatio) {
            controller.convexHandler().functionDelegateCall(
                abi.encodeWithSignature("deposit(address,uint256)", curvePool_, idleCurveLpBalance_)
            );
        }
    }

    /// @notice Get current underlying balance of pool
    function totalUnderlying() public view virtual returns (uint256) {
        (uint256 totalUnderlying_, ) = _getTotalAndPerPoolUnderlying();

        return totalUnderlying_;
    }

    function _exchangeRate(uint256 totalUnderlying_) internal view returns (uint256) {
        uint256 lpSupply = lpToken.totalSupply();
        if (lpSupply == 0 || totalUnderlying_ == 0) return ScaledMath.ONE;

        return totalUnderlying_.divDown(lpSupply);
    }

    /// @notice Get current exchange rate for the pool's LP token
    function exchangeRate() public view virtual override returns (uint256) {
        return _exchangeRate(totalUnderlying());
    }

    /// @notice Withdraw underlying
    /// @param conicLpAmount Amount of LP tokens to burn
    /// @param minUnderlyingReceived Minimum amount of underlying to redeem
    /// This should always be set to a reasonable value (e.g. 2%), otherwise
    /// the user withdrawing could be forced into paying a withdrawal penalty fee
    /// by another user
    /// @return uint256 Total underlying withdrawn
    function withdraw(uint256 conicLpAmount, uint256 minUnderlyingReceived)
        public
        override
        returns (uint256)
    {
        // Preparing Withdrawals
        ILpToken lpToken_ = lpToken;
        require(lpToken_.balanceOf(msg.sender) >= conicLpAmount, "insufficient balance");
        IERC20 underlying_ = underlying;
        uint256 underlyingBalanceBefore_ = underlying.balanceOf(address(this));

        // Processing Withdrawals
        (
            uint256 totalUnderlying_,
            uint256[] memory allocatedPerPool
        ) = _getTotalAndPerPoolUnderlying();
        uint256 underlyingToReceive_ = conicLpAmount.mulDown(_exchangeRate(totalUnderlying_));
        uint256 underlyingToWithdraw_ = underlyingToReceive_ - underlyingBalanceBefore_;
        _withdrawFromCurve(totalUnderlying_, allocatedPerPool, underlyingToWithdraw_);

        // Sending Underlying and burning LP Tokens
        uint256 underlyingBalanceAfter_ = underlying_.balanceOf(address(this));
        uint256 underlyingBalanceDiff_ = underlyingBalanceAfter_ - underlyingBalanceBefore_;
        uint256 underlyingWithdrawn_ = _min(underlyingBalanceDiff_, underlyingToReceive_);
        require(underlyingWithdrawn_ >= minUnderlyingReceived, "too much slippage");
        lpToken_.burn(msg.sender, conicLpAmount);
        underlying_.safeTransfer(msg.sender, underlyingWithdrawn_);

        _cachedTotalUnderlying = underlyingBalanceAfter_;
        _cacheUpdatedTimestamp = block.timestamp;

        emit Withdraw(msg.sender, underlyingWithdrawn_);
        return underlyingWithdrawn_;
    }

    function _withdrawFromCurve(
        uint256 totalUnderlying_,
        uint256[] memory allocatedPerPool,
        uint256 amount_
    ) internal {
        uint256 withdrawalsRemaining_ = amount_;
        uint256 totalAfterWithdrawal_ = totalUnderlying_ - amount_;

        // NOTE: avoid modifying `allocatedPerPool`
        uint256[] memory allocatedPerPoolCopy = allocatedPerPool.copy();

        while (withdrawalsRemaining_ > 0) {
            (uint256 curvePoolIndex_, uint256 maxWithdrawal_) = _getWithdrawPool(
                totalAfterWithdrawal_,
                allocatedPerPoolCopy
            );
            address curvePool_ = _curvePools.at(curvePoolIndex_);

            // Withdrawing from least balanced Curve pool
            uint256 toWithdraw_ = _min(withdrawalsRemaining_, maxWithdrawal_);
            _withdrawFromCurvePool(curvePool_, toWithdraw_);
            withdrawalsRemaining_ -= toWithdraw_;
            allocatedPerPoolCopy[curvePoolIndex_] -= toWithdraw_;
        }
    }

    function _getWithdrawPool(uint256 totalUnderlying_, uint256[] memory allocatedPerPool)
        internal
        view
        returns (uint256 withdrawPoolIndex, uint256 maxWithdrawalAmount)
    {
        uint256 curvePoolCount_ = allocatedPerPool.length;
        int256 iWithdrawPoolIndex = -1;
        for (uint256 i; i < curvePoolCount_; i++) {
            address curvePool_ = _curvePools.at(i);
            uint256 allocatedUnderlying_ = allocatedPerPool[i];
            uint256 targetAllocation_ = totalUnderlying_.mulDown(weights.get(curvePool_));
            if (allocatedUnderlying_ <= targetAllocation_) continue;
            uint256 minBalance_ = targetAllocation_ - targetAllocation_.mulDown(MAX_DEVIATION);
            uint256 maxWithdrawalAmount_ = allocatedUnderlying_ - minBalance_;
            if (maxWithdrawalAmount_ <= maxWithdrawalAmount) continue;
            maxWithdrawalAmount = maxWithdrawalAmount_;
            iWithdrawPoolIndex = int256(i);
        }
        require(iWithdrawPoolIndex > -1, "error retrieving withdraw pool");
        withdrawPoolIndex = uint256(iWithdrawPoolIndex);
    }

    function _withdrawFromCurvePool(address curvePool_, uint256 underlyingAmount_) internal {
        address curveLpToken_ = controller.curveRegistryCache().lpToken(curvePool_);
        uint256 lpToWithdraw_ = _underlyingToCurveLp(curveLpToken_, underlyingAmount_);

        controller.convexHandler().functionDelegateCall(
            abi.encodeWithSignature(
                "withdraw(address,uint256)",
                curvePool_,
                lpToWithdraw_ - _idleCurveLpBalance(curvePool_)
            )
        );

        controller.curveHandler().functionDelegateCall(
            abi.encodeWithSignature(
                "withdraw(address,address,uint256)",
                curvePool_,
                underlying,
                lpToWithdraw_
            )
        );
    }

    function allCurvePools() external view override returns (address[] memory) {
        return _curvePools.values();
    }

    function getCurvePoolAtIndex(uint256 _index) external view returns (address) {
        return _curvePools.at(_index);
    }

    function isRegisteredCurvePool(address _pool) public view returns (bool) {
        return _curvePools.contains(_pool);
    }

    function getPoolWeight(address _pool) external view returns (uint256) {
        (, uint256 _weight) = weights.tryGet(_pool);
        return _weight;
    }

    // Controller and Admin functions

    function addCurvePool(address _pool) external override onlyOwner {
        require(!_curvePools.contains(_pool), "pool already added");
        controller.curveRegistryCache().initPool(_pool);
        address curveLpToken = controller.curveRegistryCache().lpToken(_pool);
        require(controller.priceOracle().isTokenSupported(curveLpToken), "cannot price LP Token");

        address booster = controller.convexBooster();
        IERC20(curveLpToken).safeApprove(booster, type(uint256).max);

        if (!weights.contains(_pool)) weights.set(_pool, 0);
        require(_curvePools.add(_pool), "failed to add pool");
    }

    function removeCurvePool(address _pool) external override onlyOwner {
        require(_curvePools.contains(_pool), "pool not added");
        require(_curvePools.length() > 1, "cannot remove last pool");
        require(_totalCurveLpBalance(_pool) == 0, "pool has allocated funds");
        uint256 weight = weights.get(_pool);
        require(weight == 0, "pool has weight set");
        require(_curvePools.remove(_pool), "pool not removed");
        require(weights.remove(_pool), "weight not removed");
    }

    function updateWeights(PoolWeight[] memory poolWeights) external onlyController {
        uint256 total;
        for (uint256 i; i < poolWeights.length; i++) {
            address pool = poolWeights[i].poolAddress;
            require(isRegisteredCurvePool(pool), "pool is not registered");
            uint256 newWeight = poolWeights[i].weight;
            weights.set(pool, newWeight);
            emit NewWeight(pool, newWeight);
            total += newWeight;
        }

        require(total == ScaledMath.ONE, "weights do not sum to 1");

        (
            uint256 totalUnderlying_,
            uint256[] memory allocatedPerPool
        ) = _getTotalAndPerPoolUnderlying();

        uint256 totalDeviation = _computeTotalDeviation(totalUnderlying_, allocatedPerPool);
        totalDeviationAfterWeightUpdate = totalDeviation;
        rebalancingRewardActive =
            totalUnderlying_ > 0 &&
            totalDeviation.divDown(totalUnderlying_) > MAX_DEVIATION;

        // Updating price cache for all pools
        // Used for seeing if a pool has depegged
        _updatePriceCache();
    }

    function _updatePriceCache() internal {
        uint256 length_ = _curvePools.length();
        for (uint256 i; i < length_; i++) {
            address lpToken_ = controller.curveRegistryCache().lpToken(_curvePools.at(i));
            _cachedPrices[lpToken_] = controller.priceOracle().getUSDPrice(lpToken_);
        }
        address underlying_ = address(underlying);
        _cachedPrices[underlying_] = controller.priceOracle().getUSDPrice(underlying_);
    }

    function shutdownPool() external onlyOwner {
        require(!isShutdown, "pool already shutdown");
        isShutdown = true;
    }

    function updateDepegThreshold(uint256 newDepegThreshold_) external onlyOwner {
        require(newDepegThreshold_ >= _MIN_DEPEG_THRESHOLD, "invalid depeg threshold");
        require(newDepegThreshold_ <= _MAX_DEPEG_THRESHOLD, "invalid depeg threshold");
        depegThreshold = newDepegThreshold_;
    }

    /// @notice Called when an underlying of a Curve Pool has depegged and we want to exit the pool.
    /// Will check if a coin has depegged, and will revert if not.
    /// Sets the weight of the Curve Pool to 0, and re-enables CNC rewards for deposits.
    /// @dev Cannot be called if the underlying of this pool itself has depegged.
    /// @param curvePool_ The Curve Pool to handle.
    function handleDepeggedCurvePool(address curvePool_) external {
        // Validation
        require(isRegisteredCurvePool(curvePool_), "pool is not registered");
        require(weights.get(curvePool_) != 0, "pool weight already 0");
        require(!_isDepegged(address(underlying)), "underlying is depegged");
        address lpToken_ = controller.curveRegistryCache().lpToken(curvePool_);
        require(_isDepegged(lpToken_), "pool is not depegged");

        // Set target curve pool weight to 0
        // Scale up other weights to compensate
        _setWeightToZero(curvePool_);
    }

    function _setWeightToZero(address curvePool_) internal {
        uint256 weight_ = weights.get(curvePool_);
        if (weight_ == 0) return;
        require(weight_ != ScaledMath.ONE, "can't remove last pool");
        uint256 scaleUp_ = ScaledMath.ONE.divDown(ScaledMath.ONE - weights.get(curvePool_));
        uint256 curvePoolLength_ = _curvePools.length();
        for (uint256 i; i < curvePoolLength_; i++) {
            address pool_ = _curvePools.at(i);
            uint256 newWeight_ = pool_ == curvePool_ ? 0 : weights.get(pool_).mulDown(scaleUp_);
            weights.set(pool_, newWeight_);
            emit NewWeight(pool_, newWeight_);
        }

        // Updating total deviation
        (
            uint256 totalUnderlying_,
            uint256[] memory allocatedPerPool
        ) = _getTotalAndPerPoolUnderlying();
        uint256 totalDeviation = _computeTotalDeviation(totalUnderlying_, allocatedPerPool);
        totalDeviationAfterWeightUpdate = totalDeviation;
        rebalancingRewardActive = true;

        emit HandledDepeggedCurvePool(curvePool_);
    }

    function _isDepegged(address asset_) internal view returns (bool) {
        uint256 depegThreshold_ = depegThreshold;
        if (asset_ == address(underlying)) depegThreshold_ *= _DEPEG_UNDERLYING_MULTIPLIER; // Threshold is higher for underlying
        uint256 cachedPrice_ = _cachedPrices[asset_];
        uint256 currentPrice_ = controller.priceOracle().getUSDPrice(asset_);
        uint256 priceDiff_ = cachedPrice_.absSub(currentPrice_);
        uint256 priceDiffPercent_ = priceDiff_.divDown(cachedPrice_);
        return priceDiffPercent_ > depegThreshold_;
    }

    /**
     * @notice Allows anyone to set the weight of a Curve pool to 0 if the Convex pool for the
     * associated PID has been shutdown. This is a very unilkely outcome and the method does
     * not reenable rebalancing rewards.
     * @param curvePool_ Curve pool for which the Convex PID is invalid (has been shut down)
     */
    function handleInvalidConvexPid(address curvePool_) external {
        require(isRegisteredCurvePool(curvePool_), "curve pool not registered");
        uint256 pid = controller.curveRegistryCache().getPid(curvePool_);
        require(controller.curveRegistryCache().isShutdownPid(pid), "convex pool pid is shutdown");
        _setWeightToZero(curvePool_);
        emit HandledInvalidConvexPid(curvePool_, pid);
    }

    function setMaxIdleCurveLpRatio(uint256 maxIdleCurveLpRatio_) external onlyOwner {
        require(maxIdleCurveLpRatio != maxIdleCurveLpRatio_, "same as current");
        require(maxIdleCurveLpRatio_ <= _IDLE_RATIO_UPPER_BOUND, "ratio exceeds upper bound");
        maxIdleCurveLpRatio = maxIdleCurveLpRatio_;
        emit NewMaxIdleCurveLpRatio(maxIdleCurveLpRatio_);
    }

    function getWeights() external view override returns (PoolWeight[] memory) {
        uint256 length_ = _curvePools.length();
        PoolWeight[] memory weights_ = new PoolWeight[](length_);
        for (uint256 i; i < length_; i++) {
            (address pool_, uint256 weight_) = weights.at(i);
            weights_[i] = PoolWeight(pool_, weight_);
        }
        return weights_;
    }

    function getAllocatedUnderlying() external view override returns (PoolWithAmount[] memory) {
        PoolWithAmount[] memory perPoolAllocated = new PoolWithAmount[](_curvePools.length());
        (, uint256[] memory allocated) = _getTotalAndPerPoolUnderlying();

        for (uint256 i = 0; i < perPoolAllocated.length; i++) {
            perPoolAllocated[i] = PoolWithAmount(_curvePools.at(i), allocated[i]);
        }
        return perPoolAllocated;
    }

    function computeTotalDeviation() external view override returns (uint256) {
        (
            uint256 totalUnderlying_,
            uint256[] memory perPoolUnderlying
        ) = _getTotalAndPerPoolUnderlying();
        return _computeTotalDeviation(totalUnderlying_, perPoolUnderlying);
    }

    function computeDeviationRatio() external view returns (uint256) {
        (
            uint256 totalUnderlying_,
            uint256[] memory perPoolUnderlying
        ) = _getTotalAndPerPoolUnderlying();
        uint256 deviation = _computeTotalDeviation(totalUnderlying_, perPoolUnderlying);
        return deviation.divDown(totalUnderlying_);
    }

    function cachedTotalUnderlying() external view virtual override returns (uint256) {
        if (block.timestamp > _cacheUpdatedTimestamp + _TOTAL_UNDERLYING_CACHE_EXPIRY) {
            return totalUnderlying();
        }
        return _cachedTotalUnderlying;
    }

    function _getTotalAndPerPoolUnderlying() internal view returns (uint256, uint256[] memory) {
        uint256 totalUnderlying_ = underlying.balanceOf(address(this));
        uint256[] memory perPoolUnderlying_ = new uint256[](_curvePools.length());
        for (uint256 i; i < _curvePools.length(); i++) {
            address curvePool_ = _curvePools.at(i);
            uint256 poolUnderlying_ = _curveLpToUnderlying(
                controller.curveRegistryCache().lpToken(curvePool_),
                _totalCurveLpBalance(curvePool_)
            );
            perPoolUnderlying_[i] = poolUnderlying_;
            totalUnderlying_ += poolUnderlying_;
        }
        return (totalUnderlying_, perPoolUnderlying_);
    }

    function _stakedCurveLpBalance(address pool_) internal view returns (uint256) {
        return
            IBaseRewardPool(IConvexHandler(controller.convexHandler()).getRewardPool(pool_))
                .balanceOf(address(this));
    }

    function _idleCurveLpBalance(address curvePool_) internal view returns (uint256) {
        return IERC20(controller.curveRegistryCache().lpToken(curvePool_)).balanceOf(address(this));
    }

    function _totalCurveLpBalance(address curvePool_) internal view returns (uint256) {
        return _stakedCurveLpBalance(curvePool_) + _idleCurveLpBalance(curvePool_);
    }

    function _curveLpToUnderlying(address curveLpToken_, uint256 curveLpAmount_)
        internal
        view
        returns (uint256)
    {
        return
            curveLpAmount_
                .mulDown(controller.priceOracle().getUSDPrice(curveLpToken_))
                .divDown(controller.priceOracle().getUSDPrice(address(underlying)))
                .convertScale(18, IERC20Metadata(address(underlying)).decimals());
    }

    function _underlyingToCurveLp(address curveLpToken_, uint256 underlyingAmount_)
        internal
        view
        returns (uint256)
    {
        return
            underlyingAmount_
                .mulDown(controller.priceOracle().getUSDPrice(address(underlying)))
                .divDown(controller.priceOracle().getUSDPrice(curveLpToken_))
                .convertScale(IERC20Metadata(address(underlying)).decimals(), 18);
    }

    function _computeTotalDeviation(uint256 totalUnderlying_, uint256[] memory perPoolUnderlying)
        internal
        view
        returns (uint256)
    {
        uint256 totalDeviation;
        for (uint256 i; i < perPoolUnderlying.length; i++) {
            uint256 weight = weights.get(_curvePools.at(i));
            uint256 targetAmount = totalUnderlying_.mulDown(weight);
            totalDeviation += targetAmount.absSub(perPoolUnderlying[i]);
        }
        return totalDeviation;
    }

    function _handleRebalancingRewards(
        address account,
        uint256 underlyingBalanceBefore_,
        uint256[] memory allocatedPerPoolBefore,
        uint256 underlyingBalanceAfter_,
        uint256[] memory allocatedPerPoolAfter
    ) internal {
        uint256 deviationBefore = _computeTotalDeviation(
            underlyingBalanceBefore_,
            allocatedPerPoolBefore
        );
        uint256 deviationAfter = _computeTotalDeviation(
            underlyingBalanceAfter_,
            allocatedPerPoolAfter
        );

        controller.inflationManager().handleRebalancingRewards(
            account,
            deviationBefore,
            deviationAfter
        );

        uint256 deviationRatio = deviationAfter.divDown(underlyingBalanceAfter_);
        if (deviationRatio < MAX_DEVIATION) {
            rebalancingRewardActive = false;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
