// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "./ConicPoolBaseTest.sol";
import "../interfaces/vendor/IBooster.sol";

contract ConicPoolTest is ConicPoolBaseTest {
    ConicPool public conicPool;
    IERC20Metadata public underlying;
    uint256 public decimals;

    function setUp() public override {
        super.setUp();
        underlying = IERC20Metadata(Tokens.DAI);
        decimals = underlying.decimals();
        setTokenBalance(bb8, address(underlying), 100_000 * 10**decimals);
        conicPool = _createConicPool(
            controller,
            rewardsHandler,
            locker,
            address(underlying),
            "Conic DAI",
            "cncDAI"
        );

        conicPool.addCurvePool(CurvePools.FRAX_3CRV);
        conicPool.addCurvePool(CurvePools.TRI_POOL);

        IConicPool.PoolWeight[] memory weights = new IConicPool.PoolWeight[](2);
        weights[0] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0.6e18);
        weights[1] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 0.4e18);
        _setWeights(address(conicPool), weights);
    }

    function testInitialState() public {
        assertEq(address(conicPool.controller()), address(controller));
        assertEq(conicPool.lpToken().name(), "Conic DAI");
        assertEq(conicPool.lpToken().symbol(), "cncDAI");
        assertEq(address(conicPool.underlying()), address(underlying));
        assertFalse(conicPool.isShutdown());
        assertFalse(conicPool.rebalancingRewardActive());
        assertEq(conicPool.depegThreshold(), 0.03e18);
        assertEq(conicPool.maxIdleCurveLpRatio(), 0.05e18);
    }

    function testDepositWithoutStaking() public {
        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);

        uint256 balanceBefore = conicPool.lpToken().balanceOf(bb8);
        conicPool.deposit(10_000 * 10**decimals, 1, false);
        uint256 lpReceived = conicPool.lpToken().balanceOf(bb8) - balanceBefore;
        assertApproxEqRel(10_000 * 10**decimals, lpReceived, 0.01e18);

        _checkAllocations();
    }

    function testDepositAndStake() public {
        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);

        conicPool.deposit(10_000 * 10**decimals, 1);
        uint256 lpReceived = controller.lpTokenStaker().getUserBalanceForPool(
            address(conicPool),
            bb8
        );
        assertApproxEqRel(10_000 * 10**decimals, lpReceived, 0.01e18);
        _checkAllocations();
    }

    function testWidthrawWithoutStaking() public {
        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);

        conicPool.deposit(10_000 * 10**decimals, 1, false);
        uint256 balanceBeforeWithdraw = underlying.balanceOf(bb8);
        uint256 lpBalanceBeforeWithdraw = conicPool.lpToken().balanceOf(bb8);
        conicPool.withdraw(5_000 * 10**decimals, 1);
        uint256 lpDiff = lpBalanceBeforeWithdraw - conicPool.lpToken().balanceOf(bb8);
        assertApproxEqRel(5_000 * 10**decimals, lpDiff, 0.01e18);
        uint256 underlyingReceived = underlying.balanceOf(bb8) - balanceBeforeWithdraw;
        assertApproxEqRel(5_000 * 10**decimals, underlyingReceived, 0.01e18);
        _checkAllocations();
    }

    function testWidthrawWithStaking() public {
        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);

        conicPool.deposit(10_000 * 10**decimals, 1);
        uint256 balanceBeforeWithdraw = underlying.balanceOf(bb8);
        uint256 lpBalanceBeforeWithdraw = controller.lpTokenStaker().getUserBalanceForPool(
            address(conicPool),
            bb8
        );
        conicPool.unstakeAndWithdraw(5_000 * 10**decimals, 1);
        uint256 lpDiff = lpBalanceBeforeWithdraw -
            controller.lpTokenStaker().getUserBalanceForPool(address(conicPool), bb8);
        assertApproxEqRel(5_000 * 10**decimals, lpDiff, 0.01e18);
        uint256 underlyingReceived = underlying.balanceOf(bb8) - balanceBeforeWithdraw;
        assertApproxEqRel(5_000 * 10**decimals, underlyingReceived, 0.01e18);
        _checkAllocations();
    }

    function testWithdrawWithV0Pool() public {
        conicPool.addCurvePool(CurvePools.SUSD_DAI_USDT_USDC);
        IConicPool.PoolWeight[] memory newWeights = new IConicPool.PoolWeight[](3);
        newWeights[0] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0.6e18);
        newWeights[1] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 0.3e18);
        newWeights[2] = IConicPool.PoolWeight(CurvePools.SUSD_DAI_USDT_USDC, 0.1e18);
        skip(14 days);
        _setWeights(address(conicPool), newWeights);

        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);
        conicPool.deposit(10_000 * 10**decimals, 1);
        uint256 balanceBeforeWithdraw = underlying.balanceOf(bb8);
        uint256 lpBalanceBeforeWithdraw = controller.lpTokenStaker().getUserBalanceForPool(
            address(conicPool),
            bb8
        );
        conicPool.unstakeAndWithdraw(5_000 * 10**decimals, 1);
        uint256 lpDiff = lpBalanceBeforeWithdraw -
            controller.lpTokenStaker().getUserBalanceForPool(address(conicPool), bb8);
        assertApproxEqRel(5_000 * 10**decimals, lpDiff, 0.01e18);
        uint256 underlyingReceived = underlying.balanceOf(bb8) - balanceBeforeWithdraw;
        assertApproxEqRel(5_000 * 10**decimals, underlyingReceived, 0.01e18);
    }

    function testRebalance() public {
        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);

        conicPool.deposit(10_000 * 10**decimals, 1);
        vm.stopPrank();

        skip(14 days);

        IConicPool.PoolWeight[] memory newWeights = new IConicPool.PoolWeight[](2);
        newWeights[0] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0.8e18);
        newWeights[1] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 0.2e18);
        _setWeights(address(conicPool), newWeights);

        skip(1 hours);

        assertTrue(conicPool.rebalancingRewardActive());

        uint256 deviationBefore = conicPool.computeTotalDeviation();
        uint256 cncBalanceBefore = IERC20(controller.cncToken()).balanceOf(bb8);
        vm.prank(bb8);
        conicPool.deposit(10_000 * 10**decimals, 1);
        uint256 deviationAfter = conicPool.computeTotalDeviation();
        assertLt(deviationAfter, deviationBefore);
        uint256 cncBalanceAfter = IERC20(controller.cncToken()).balanceOf(bb8);
        assertGt(cncBalanceAfter, cncBalanceBefore);
    }

    function testClaimRewards() public {
        vm.startPrank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);
        IRewardManager rewardManager = conicPool.rewardManager();

        conicPool.deposit(10_000 * 10**decimals, 1);
        skip(1 days);
        (uint256 cncRewards, uint256 crvRewards, uint256 cvxRewards) = rewardManager
            .claimableRewards(bb8);
        assertGt(cncRewards, 0);
        assertGt(crvRewards, 0);
        assertGt(cvxRewards, 0);

        (uint256 cncClaimed, uint256 crvClaimed, uint256 cvxClaimed) = rewardManager
            .claimEarnings();
        assertEq(cncClaimed, cncRewards);
        assertEq(crvClaimed, crvRewards);
        assertEq(cvxClaimed, cvxRewards);
    }

    function testHandleInvalidConvexPid() public {
        address[] memory pools = conicPool.allCurvePools();
        address curvePool = pools[0];
        vm.expectRevert("convex pool pid is shutdown");
        conicPool.handleInvalidConvexPid(curvePool);
        uint256 pid = controller.curveRegistryCache().getPid(curvePool);
        vm.mockCall(
            address(controller.curveRegistryCache().BOOSTER()),
            abi.encodeWithSelector(IBooster.poolInfo.selector, pid),
            abi.encode(
                address(0), // lpToken
                address(0), // token,
                address(0), // gauge,
                address(0), // crvRewards,
                address(0), // stash,
                true // shutdown
            )
        );

        conicPool.handleInvalidConvexPid(curvePool);
        assertEq(conicPool.getPoolWeight(curvePool), 0);
        _ensureWeightsSumTo1(conicPool);
    }

    function testHandleDepeggedPool() public {
        address[] memory pools = conicPool.allCurvePools();
        address curvePool = pools[0];
        vm.expectRevert("pool is not depegged");
        conicPool.handleDepeggedCurvePool(curvePool);

        address lpToken = controller.curveRegistryCache().lpToken(curvePool);
        uint256 price = controller.priceOracle().getUSDPrice(lpToken);
        vm.mockCall(
            address(controller.priceOracle()),
            abi.encodeWithSelector(IOracle.getUSDPrice.selector, lpToken),
            abi.encode((price * 95) / 100)
        );
        conicPool.handleDepeggedCurvePool(curvePool);
        assertEq(conicPool.getPoolWeight(curvePool), 0);
        _ensureWeightsSumTo1(conicPool);
    }

    function testRemovePool() public {
        vm.prank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);
        vm.prank(bb8);
        conicPool.deposit(10_000 * 10**decimals, 1, false);

        address[] memory pools = conicPool.allCurvePools();
        address curvePool = pools[0];

        vm.expectRevert("pool has allocated funds");
        conicPool.removeCurvePool(curvePool);

        skip(14 days);

        IConicPool.PoolWeight[] memory newWeights = new IConicPool.PoolWeight[](2);
        newWeights[0] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0);
        newWeights[1] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 1e18);
        _setWeights(address(conicPool), newWeights);

        vm.prank(bb8);
        conicPool.withdraw(9_000 * 10**decimals, 1);

        conicPool.removeCurvePool(curvePool);
        address[] memory newPools = conicPool.allCurvePools();
        assertEq(newPools.length, pools.length - 1);
        for (uint256 i = 0; i < newPools.length; i++) {
            if (newPools[i] == curvePool) fail("pool not removed");
        }
    }

    function testRemoveAndAddPool() public {
        vm.prank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);
        vm.prank(bb8);
        conicPool.deposit(10_000 * 10**decimals, 1, false);
        address[] memory pools = conicPool.allCurvePools();
        address curvePool = pools[0];

        skip(14 days);

        IConicPool.PoolWeight[] memory newWeights = new IConicPool.PoolWeight[](2);
        newWeights[0] = IConicPool.PoolWeight(CurvePools.FRAX_3CRV, 0);
        newWeights[1] = IConicPool.PoolWeight(CurvePools.TRI_POOL, 1e18);
        _setWeights(address(conicPool), newWeights);

        vm.prank(bb8);
        conicPool.withdraw(9_000 * 10**decimals, 1);
        conicPool.removeCurvePool(curvePool);

        conicPool.addCurvePool(curvePool);
        address[] memory newPools = conicPool.allCurvePools();
        assertEq(newPools.length, pools.length);
        for (uint256 i = 0; i < newPools.length; i++) {
            for (uint256 j = 0; j < newPools.length; j++) {
                if (newPools[i] == pools[j]) break;
                if (j == newPools.length - 1) fail("pool not added");
            }
        }
    }

    function testSetMaxIdleCurveLpRatio() public {
        uint256 currentRatio = conicPool.maxIdleCurveLpRatio();
        vm.expectRevert("same as current");
        conicPool.setMaxIdleCurveLpRatio(currentRatio);

        vm.expectRevert("ratio exceeds upper bound");
        conicPool.setMaxIdleCurveLpRatio(0.21e18);

        conicPool.setMaxIdleCurveLpRatio(0.15e18);
        assertEq(conicPool.maxIdleCurveLpRatio(), 0.15e18);
    }

    function testUpdateDepegThreshold() public {
        vm.expectRevert("invalid depeg threshold");
        conicPool.updateDepegThreshold(0.009e18);

        vm.expectRevert("invalid depeg threshold");
        conicPool.updateDepegThreshold(0.11e18);

        conicPool.updateDepegThreshold(0.05e18);
        assertEq(conicPool.depegThreshold(), 0.05e18);
    }

    function testShutdown() public {
        vm.expectRevert("not authorized");
        conicPool.shutdownPool();

        vm.prank(bb8);
        underlying.approve(address(conicPool), 100_000 * 10**decimals);
        vm.prank(bb8);
        conicPool.deposit(10_000 * 10**decimals, 1, false);

        vm.prank(address(controller));
        conicPool.shutdownPool();
        assertTrue(conicPool.isShutdown());

        vm.prank(bb8);
        vm.expectRevert("pool is shutdown");
        conicPool.deposit(10_000 * 10**decimals, 1, false);

        uint256 balanceBeforeWithdraw = underlying.balanceOf(bb8);
        uint256 lpAmount = conicPool.lpToken().balanceOf(bb8);
        vm.prank(bb8);
        conicPool.withdraw(lpAmount, 1);
        uint256 underlyingReceived = underlying.balanceOf(bb8) - balanceBeforeWithdraw;
        assertApproxEqRel(10_000 * 10**decimals, underlyingReceived, 0.01e18);
    }

    function _checkAllocations() internal {
        IConicPool.PoolWithAmount[] memory allocations = conicPool.getAllocatedUnderlying();
        uint256 totalUnderlying = conicPool.totalUnderlying();
        IConicPool.PoolWeight[] memory weights = conicPool.getWeights();
        for (uint256 i = 0; i < allocations.length; i++) {
            uint256 expected = (totalUnderlying * weights[i].weight) / 1e18;
            assertApproxEqRel(allocations[i].amount, expected, 0.03e18);
        }
        assertLt(conicPool.computeDeviationRatio(), 0.03e18);
    }
}
