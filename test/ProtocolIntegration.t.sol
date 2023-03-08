// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "./ConicPoolBaseTest.sol";
import "../interfaces/vendor/IBooster.sol";

contract XorShiftPRNG {
    uint256 internal seed;

    constructor(uint256 _seed) {
        seed = _seed;
    }

    function resetSeed(uint256 _seed) external {
        seed = _seed;
    }

    function xorShift() public returns (uint256) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        return seed;
    }
}

contract ProtocolIntegrationTest is ConicPoolBaseTest {
    using ScaledMath for uint256;

    address[] public actors;

    XorShiftPRNG internal prng;

    ConicPool[] public pools;

    function setUp() public virtual override {
        super.setUp();
        _setFork(mainnetFork);

        prng = new XorShiftPRNG(0);

        _initializeActors();
        _initializeContracts();
        _addPool(_createDAIPool());
        _addPool(_createUSDCPool());
        _addPool(_createFRAXPool());
    }

    function testFullScenario(uint256 seed) public {
        prng.resetSeed(seed);

        for (uint256 n; n < 10; n++) {
            uint256 nOperations = _boundValue(prng.xorShift(), 20, 200);
            for (uint256 i; i < nOperations; i++) {
                if (_randomInt(0, 3) == 0) {
                    _withdraw(_randomInt(), _randomActor(), _randomPool(), _randomBool());
                } else {
                    _deposit(_randomInt(), _randomActor(), _randomPool(), _randomBool());
                }

                _randomSkip();

                if (_randomInt(0, 5) == 0) {
                    _depositAndWithdraw(_randomInt(), _randomActor(), _randomPool(), _randomBool());
                    _randomSkip();
                }
            }
            inflationManager.updatePoolWeights();

            skip(1 hours);

            for (uint256 j; j < pools.length; j++) {
                address pool = address(pools[j]);
                if (lpTokenStaker.getBalanceForPool(pool) > 0)
                    assertGt(lpTokenStaker.claimableCnc(pool), 0, "no rewards for pool");
                for (uint256 i; i < actors.length; i++) {
                    if (_randomInt(0, 3) == 0) _claimRewards(actors[i], pools[j]);
                }
            }

            console.log("Running LAV %d", n);

            skip(14 days);
            _executeLAV();
            skip(3600);
        }
    }

    function _claimRewards(address actor, ConicPool pool) internal {
        IERC20Metadata crv = IERC20Metadata(Tokens.CRV);
        IERC20Metadata cvx = IERC20Metadata(Tokens.CVX);
        uint256 cncBefore = cnc.balanceOf(actor);
        uint256 crvBefore = crv.balanceOf(actor);
        uint256 cvxBefore = cvx.balanceOf(actor);
        IRewardManager rewardManager = pool.rewardManager();
        vm.prank(actor);
        (uint256 cncRewards, uint256 crvRewards, uint256 cvxRewards) = rewardManager
            .claimEarnings();
        assertEq(cnc.balanceOf(actor), cncBefore + cncRewards, "wrong cnc rewards");
        assertEq(crv.balanceOf(actor), crvBefore + crvRewards, "wrong crv rewards");
        assertEq(cvx.balanceOf(actor), cvxBefore + cvxRewards, "wrong cvx rewards");
        if (lpTokenStaker.getUserBalanceForPool(address(pool), actor) > 0) {
            assertGt(cncRewards, 0, "user did not receive cnc rewards");
        }
    }

    function _deposit(
        uint256 amount,
        address actor,
        ConicPool pool,
        bool stake
    ) internal useActor(actor) withRebalancingRewardsInvariant(pool, actor) {
        _executeDeposit(amount, actor, pool, stake);
    }

    function _executeDeposit(
        uint256 amount,
        address actor,
        ConicPool pool,
        bool stake
    ) internal returns (uint256) {
        IERC20Metadata underlying = pool.underlying();
        amount = _boundValue(
            amount,
            _scale(1, underlying.decimals()),
            _scale(100_000, underlying.decimals())
        );
        setTokenBalance(actor, address(underlying), amount);
        underlying.approve(address(pool), amount);
        uint256 lpBeforeDeposit = _getTotalLp(pool, actor);
        uint256 minReceived = (amount * 8) / 10;
        uint256 amountReceived = pool.deposit(amount, minReceived, stake);
        uint256 lpAfterDeposit = _getTotalLp(pool, actor);
        assertGe(amountReceived, minReceived);
        assertEq(amountReceived, lpAfterDeposit - lpBeforeDeposit, "wrong amount received");
        assertEq(underlying.balanceOf(actor), 0, "non-zero underlying");
        return amountReceived;
    }

    function _withdraw(
        uint256 amount,
        address actor,
        ConicPool pool,
        bool unstake
    ) internal useActor(actor) {
        uint256 maxAmount;
        if (unstake) {
            maxAmount = lpTokenStaker.getUserBalanceForPool(address(pool), actor);
        } else {
            maxAmount = pool.lpToken().balanceOf(actor);
        }
        if (maxAmount == 0) return;

        amount = _boundValue(amount, 0, maxAmount);
        _executeWithdraw(amount, actor, pool, unstake);
    }

    function _depositAndWithdraw(
        uint256 amount,
        address actor,
        ConicPool pool,
        bool stake
    ) internal useActor(actor) withDeviationInvariant(pool) {
        uint256 totalDeviationBefore = pool.computeDeviationRatio();

        uint256 received = _executeDeposit(amount, actor, pool, stake);
        _executeWithdraw(received, actor, pool, stake);

        uint256 totalDeviationAfter = pool.computeDeviationRatio();
        if (pool.rebalancingRewardActive()) {
            assertLe(
                totalDeviationAfter,
                totalDeviationBefore,
                "deviation did not decrease after deposit/withdrawal"
            );
        }
    }

    function _executeWithdraw(
        uint256 amount,
        address actor,
        ConicPool pool,
        bool unstake
    ) internal {
        IERC20Metadata underlying = pool.underlying();
        uint256 minReceived = (amount * 8) / 10;

        uint256 underlyingBeforeWithdraw = underlying.balanceOf(actor);

        uint256 underlyingWithdrawn;
        if (unstake) {
            underlyingWithdrawn = pool.unstakeAndWithdraw(amount, minReceived);
        } else {
            underlyingWithdrawn = pool.withdraw(amount, minReceived);
        }

        assertEq(
            underlyingWithdrawn,
            underlying.balanceOf(actor) - underlyingBeforeWithdraw,
            "wrong amount withdrawn"
        );
        assertGe(underlyingWithdrawn, minReceived);
    }

    function _executeLAV() internal {
        IController.WeightUpdate[] memory weightUpdates = new IController.WeightUpdate[](
            pools.length
        );
        for (uint256 i; i < pools.length; i++) {
            IConicPool.PoolWeight[] memory newWeights = _getNewRandomWeights(pools[i]);
            weightUpdates[i] = IController.WeightUpdate(address(pools[i]), newWeights);
        }
        controller.updateAllWeights(weightUpdates);
    }

    function _scale(uint256 amount, uint256 decimals) internal pure returns (uint256) {
        return amount * 10**decimals;
    }

    function _initializeActors() internal {
        actors.push(makeAddr("bb8"));
        actors.push(makeAddr("r2"));
        actors.push(makeAddr("c3p0"));
        actors.push(makeAddr("wicket"));
        actors.push(makeAddr("jango"));
        actors.push(makeAddr("luke"));
        actors.push(makeAddr("leia"));
    }

    function _addPool(ConicPool pool) internal {
        pools.push(pool);
    }

    function _createDAIPool() internal returns (ConicPool daiPool) {
        daiPool = _createConicPool(
            controller,
            rewardsHandler,
            locker,
            Tokens.DAI,
            "Conic DAI",
            "cncDAI"
        );

        daiPool.addCurvePool(CurvePools.FRAX_3CRV);
        daiPool.addCurvePool(CurvePools.TRI_POOL);
        daiPool.addCurvePool(CurvePools.SUSD_DAI_USDT_USDC);
        IConicPool.PoolWeight[] memory weights = new IConicPool.PoolWeight[](3);
        weights[0] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0.2077e18);
        weights[1] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 0.5562e18);
        weights[2] = IConicPool.PoolWeight(CurvePools.SUSD_DAI_USDT_USDC, 0.2361e18);
        _setWeights(address(daiPool), weights);
    }

    function _createUSDCPool() internal returns (ConicPool usdcPool) {
        usdcPool = _createConicPool(
            controller,
            rewardsHandler,
            locker,
            Tokens.USDC,
            "Conic USDC",
            "cncUSDC"
        );

        usdcPool.addCurvePool(CurvePools.TRI_POOL);
        usdcPool.addCurvePool(CurvePools.FRAX_BP);
        usdcPool.addCurvePool(CurvePools.FRAX_3CRV);
        usdcPool.addCurvePool(CurvePools.SUSD_DAI_USDT_USDC);
        IConicPool.PoolWeight[] memory weights = new IConicPool.PoolWeight[](4);
        weights[0] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 0.4459e18);
        weights[1] = IConicPool.PoolWeight(CurvePools.FRAX_BP, 0.1998e18);
        weights[2] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0.1963e18);
        weights[3] = IConicPool.PoolWeight(CurvePools.SUSD_DAI_USDT_USDC, 0.158e18);
        _setWeights(address(usdcPool), weights);
    }

    function _createFRAXPool() internal returns (ConicPool fraxPool) {
        fraxPool = _createConicPool(
            controller,
            rewardsHandler,
            locker,
            Tokens.FRAX,
            "Conic FRAX",
            "cncFRAX"
        );

        fraxPool.addCurvePool(CurvePools.FRAX_BP);
        fraxPool.addCurvePool(CurvePools.GUSD_FRAX_BP);
        fraxPool.addCurvePool(CurvePools.FRAX_3CRV);
        IConicPool.PoolWeight[] memory weights = new IConicPool.PoolWeight[](3);
        weights[0] = IConicPool.PoolWeight(CurvePools.FRAX_BP, 0.4452e18);
        weights[1] = IConicPool.PoolWeight(CurvePools.GUSD_FRAX_BP, 0.129e18);
        weights[2] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0.4258e18);
        _setWeights(address(fraxPool), weights);
    }

    function _getTotalLp(ConicPool pool, address actor) internal view returns (uint256) {
        return
            pool.lpToken().balanceOf(actor) +
            lpTokenStaker.getUserBalanceForPool(address(pool), actor);
    }

    function _randomInt() internal returns (uint256) {
        return prng.xorShift();
    }

    function _randomInt(uint256 min, uint256 max) internal returns (uint256) {
        return _boundValue(prng.xorShift(), min, max);
    }

    function _randomBool() internal returns (bool) {
        return prng.xorShift() % 2 == 0;
    }

    function _randomActor() internal returns (address) {
        return actors[_boundValue(prng.xorShift(), 0, actors.length - 1)];
    }

    function _randomPool() internal returns (ConicPool) {
        return pools[_boundValue(prng.xorShift(), 0, pools.length - 1)];
    }

    function _randomSkip() internal {
        if (_randomInt(0, 19) == 0) return;
        uint256 secondsToSkip = _boundValue(prng.xorShift(), 12, 3600);
        skip(secondsToSkip);
    }

    function _getNewRandomWeights(ConicPool pool)
        internal
        returns (IConicPool.PoolWeight[] memory weights)
    {
        address[] memory curvePools = pool.allCurvePools();
        weights = new IConicPool.PoolWeight[](curvePools.length);
        uint256 leftToAssign = 1e18;
        for (uint256 i = 0; i < curvePools.length; i++) {
            uint256 weight;
            // 10% prob of assigning 0 weight to a pool that is not the last one
            // the last one might be 0 once in a while if the other pools use up
            // all the weights
            if (i != weights.length - 1 && _randomInt(0, 9) == 1) {
                weight = 0;
            } else if (i == weights.length - 1 || leftToAssign < 0.05e18) {
                weight = leftToAssign;
            } else {
                weight = _randomInt(0.05e18, leftToAssign);
            }
            weights[i] = IConicPool.PoolWeight(curvePools[i], weight);
            leftToAssign -= weight;
        }
    }

    modifier useActor(address actor) {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier withDeviationInvariant(ConicPool pool) {
        uint256 totalDeviationBefore = pool.computeDeviationRatio();
        _;
        uint256 totalDeviationAfter = pool.computeDeviationRatio();
        if (pool.rebalancingRewardActive()) {
            assertLe(
                totalDeviationAfter,
                totalDeviationBefore,
                "deviation did not decrease after deposit/withdrawal"
            );
        }
    }

    function _getWeights(ConicPool pool) internal view returns (uint256[] memory result) {
        IConicPool.PoolWeight[] memory weights = pool.getWeights();
        result = new uint256[](weights.length);
        for (uint256 i = 0; i < pool.curvePoolsCount(); i++) {
            result[i] = weights[i].weight;
        }
    }

    function _getAllocated(ConicPool pool) internal view returns (uint256[] memory result) {
        IConicPool.PoolWithAmount[] memory allocated = pool.getAllocatedUnderlying();
        result = new uint256[](allocated.length);
        for (uint256 i = 0; i < pool.curvePoolsCount(); i++) {
            result[i] = allocated[i].amount;
        }
    }

    modifier withRebalancingRewardsInvariant(ConicPool pool, address actor) {
        uint256 balanceBefore = cnc.balanceOf(actor);
        bool rewardsActive = pool.rebalancingRewardActive();
        uint256 totalDeviationBefore = pool.computeTotalDeviation();
        _;
        if (rewardsActive && pool.computeTotalDeviation() < totalDeviationBefore) {
            assertGt(pool.cachedTotalUnderlying(), 0, "pool has no underlying");
            assertGt(
                cnc.balanceOf(actor),
                balanceBefore,
                "did not receive any rebalancing rewards"
            );
        } else {
            assertEq(cnc.balanceOf(actor), balanceBefore, "rewards received while inactive");
        }
    }

    function _getCurrentWeights(ConicPool pool)
        internal
        view
        returns (IConicPool.PoolWeight[] memory)
    {
        uint256 length_ = pool.curvePoolsCount();
        IConicPool.PoolWeight[] memory weights_ = new IConicPool.PoolWeight[](length_);
        uint256 totalWeight;
        for (uint256 i; i < length_; i++) {
            (, uint256 allocatedUnderlying_, uint256[] memory allocatedPerPool) = pool
                .getTotalAndPerPoolUnderlying();
            uint256 poolWeight = allocatedPerPool[i].divUp(allocatedUnderlying_);
            if (poolWeight + totalWeight > 1e18) {
                poolWeight = 1e18 - totalWeight;
            }
            weights_[i] = IConicPool.PoolWeight(pool.getCurvePoolAtIndex(i), poolWeight);
            totalWeight += poolWeight;
        }
        return weights_;
    }

    function _computeDeviations(ConicPool pool) internal view returns (uint256[] memory) {
        IConicPool.PoolWeight[] memory targetWeights = pool.getWeights();
        IConicPool.PoolWeight[] memory actualWeights = _getCurrentWeights(pool);
        uint256[] memory deviations = new uint256[](actualWeights.length);
        for (uint256 i; i < actualWeights.length; i++) {
            deviations[i] = actualWeights[i].weight.absSub(targetWeights[i].weight);
        }
        return deviations;
    }

    function _getPoolsLpBalances(ConicPool pool) internal view returns (uint256[] memory) {
        address[] memory curvePools = pool.allCurvePools();
        uint256[] memory balances = new uint256[](curvePools.length);
        for (uint256 i; i < balances.length; i++) {
            balances[i] = pool.totalCurveLpBalance(curvePools[i]);
        }
        return balances;
    }

    function _boundValue(
        uint256 value,
        uint256 min,
        uint256 max
    ) internal pure returns (uint256) {
        return (value % (max - min + 1)) + min;
    }
}
