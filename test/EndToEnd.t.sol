// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

// import "forge-std/Test.sol";
import "../lib/forge-std/src/Test.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/pools/IConicPool.sol";
import "../interfaces/access/IGovernanceProxy.sol";
import "../interfaces/IController.sol";
import "../interfaces/tokenomics/ILpTokenStaker.sol";
import "../lib/forge-std/src/console2.sol";

contract EndToEndTest is Test {
    using stdJson for string;
    using stdStorage for StdStorage;

    address public constant DEPLOYER = address(0xedaEb101f34d767f263c0fe6B8d494E3d071F0bA);

    address[] public poolAddresses;
    ILpTokenStaker public lpTokenStaker;
    IController public controller;
    IERC20Metadata public cnc;
    IGovernanceProxy public governanceProxy;

    address public bb8 = makeAddr("bb8");

    function setTokenBalance(
        address who,
        address token,
        uint256 amt
    ) internal {
        bytes4 sel = IERC20(token).balanceOf.selector;
        stdstore.target(token).sig(sel).with_key(who).checked_write(amt);
    }

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/build/deployments/map.json");
        string memory json = vm.readFile(path);
        lpTokenStaker = ILpTokenStaker(json.readAddress(".1337.LpTokenStaker[0]"));
        poolAddresses = json.readAddressArray(".1337.ConicPool");
        controller = IController(json.readAddress(".1337.Controller[0]"));
        governanceProxy = IGovernanceProxy(json.readAddress(".1337.GovernanceProxy[0]"));
        cnc = IERC20Metadata(controller.cncToken());
        assertEq(poolAddresses.length, 3);
    }

    function testDepositAndWithdraw() public {
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            _testDepositAndWithdraw(poolAddresses[i]);
            _testRebalance(poolAddresses[i]);
            _testWithdrawAfterRebalance(poolAddresses[i]);
            _testRemovePool(poolAddresses[i]);
        }
    }

    function _testDepositAndWithdraw(address poolAddress) internal {
        IConicPool pool = IConicPool(poolAddress);
        IERC20Metadata token = IERC20Metadata(pool.underlying());
        console2.log("-----");
        console.log("Pool: %s", token.symbol());
        uint256 depositAmount = 10_000 * 10**token.decimals();
        setTokenBalance(bb8, address(token), 100_000 * 10**token.decimals());
        vm.startPrank(bb8);

        token.approve(poolAddress, 10_000 * 10**token.decimals());
        pool.deposit(depositAmount, 1);
        uint256 stakedBalance = lpTokenStaker.getUserBalanceForPool(address(pool), bb8);
        assertApproxEqRel(stakedBalance, depositAmount, 0.1e18);

        uint256 underlyingBefore = token.balanceOf(bb8);
        uint256 withdrawAmount = stakedBalance / 2;
        uint256 totalUnderlying = pool.totalUnderlying();
        pool.unstakeAndWithdraw(withdrawAmount, withdrawAmount / 2);
        uint256 underlyingDiff = token.balanceOf(bb8) - underlyingBefore;
        assertApproxEqRel(pool.totalUnderlying(), totalUnderlying - withdrawAmount, 0.1e18);
        assertApproxEqRel(depositAmount / 2, underlyingDiff, 0.1e18);

        vm.stopPrank();
    }

    function _testRebalance(address poolAddress) internal {
        IConicPool pool = IConicPool(poolAddress);
        IERC20Metadata token = IERC20Metadata(pool.underlying());
        IConicPool.PoolWithAmount[] memory allocatedUnderlying = pool.getAllocatedUnderlying();
        assertGt(allocatedUnderlying.length, 0);
        assertGt(allocatedUnderlying[0].amount, 0);
        IConicPool.PoolWeight[] memory weights = pool.getWeights();
        // Here we are removing all weight from the first pool and adding it to the second one
        uint256 firstWeight = weights[0].weight;
        assertGt(firstWeight, 0);
        weights[0].weight = 0;
        weights[1].weight = firstWeight + weights[1].weight;
        IController.WeightUpdate[] memory weightUpdates = new IController.WeightUpdate[](1);
        weightUpdates[0].conicPoolAddress = poolAddress;
        weightUpdates[0].weights = weights;
        vm.warp(block.timestamp + 14 days);
        _proxyCall(
            address(controller),
            abi.encodeWithSignature(
                "updateAllWeights((address,(address,uint256)[])[])",
                weightUpdates
            ),
            3
        );
        IConicPool.PoolWeight[] memory newWeights = pool.getWeights();
        address firstPoolAddress = newWeights[0].poolAddress;
        assertEq(newWeights[0].weight, 0);

        vm.startPrank(bb8);
        uint256 cncBalanceBefore = token.balanceOf(bb8);
        uint8 decimals = token.decimals();
        uint256 amount = 10_000 * 10**decimals;
        token.approve(poolAddress, amount);
        assertEq(pool.rebalancingRewardActive(), true);
        console2.log("-----");
        console2.log("Before deposit:");
        _printAllocations(pool.getAllocatedUnderlying(), decimals);
        pool.deposit(amount, 1, false);
        console2.log("-----");
        console2.log("After deposit:");
        _printAllocations(pool.getAllocatedUnderlying(), decimals);
        IERC20Metadata lpToken = IERC20Metadata(pool.lpToken());
        uint256 lpBalance = lpToken.balanceOf(bb8);
        assertGt(lpBalance, 0);
        console2.log("-----");
        console2.log("Before withdrawal:");
        _printAllocations(pool.getAllocatedUnderlying(), decimals);
        pool.withdraw(lpBalance, 1);
        console2.log("-----");
        console2.log("After withdrawal:");
        _printAllocations(pool.getAllocatedUnderlying(), decimals);
        vm.stopPrank();

        uint256 cncBalanceAfter = token.balanceOf(bb8);
        uint256 allocatedUnderlyingBefore = allocatedUnderlying[1].amount;
        IConicPool.PoolWithAmount[] memory newAllocatedUnderlying = pool.getAllocatedUnderlying();
        assertEq(newAllocatedUnderlying[0].poolAddress, firstPoolAddress);
        console2.log(newAllocatedUnderlying[0].amount);
        assertLt(newAllocatedUnderlying[0].amount, 60 * 10**decimals);
        assertGt(newAllocatedUnderlying[1].amount, allocatedUnderlyingBefore);
    }

    function _testWithdrawAfterRebalance(address poolAddress) internal {
        IConicPool pool = IConicPool(poolAddress);
        IERC20Metadata token = IERC20Metadata(pool.underlying());
        vm.startPrank(bb8);
        uint256 withdrawAmount = 1_500 * 10**token.decimals();
        pool.unstakeAndWithdraw(withdrawAmount, withdrawAmount / 2);
        vm.stopPrank();
    }

    function _testRemovePool(address poolAddress) internal {
        IConicPool pool = IConicPool(poolAddress);
        address[] memory curvePools = pool.allCurvePools();
        _proxyCall(
            address(pool),
            abi.encodeWithSignature("removeCurvePool(address)", curvePools[0]),
            0
        );
    }

    function _printAllocations(
        IConicPool.PoolWithAmount[] memory allocatedUnderlying,
        uint8 decimals
    ) internal {
        uint256 total_allocation;
        for (uint256 i; i < allocatedUnderlying.length; i++) {
            total_allocation += allocatedUnderlying[i].amount;
        }

        for (uint256 i; i < allocatedUnderlying.length; i++) {
            console2.log(allocatedUnderlying[i].poolAddress);
            console2.log(
                "%s %s%",
                allocatedUnderlying[i].amount / 10**decimals,
                (allocatedUnderlying[i].amount * 100) / total_allocation
            );
        }
    }

    function _proxyCall(
        address target,
        bytes memory data,
        uint256 delay
    ) internal returns (bytes memory) {
        vm.startPrank(DEPLOYER);
        IGovernanceProxy.Call[] memory calls = new IGovernanceProxy.Call[](1);
        calls[0] = IGovernanceProxy.Call({target: target, data: data});
        governanceProxy.requestChange(calls);
        if (delay > 0) {
            IGovernanceProxy.Change[] memory changes = governanceProxy.getPendingChanges();
            IGovernanceProxy.Change memory change = changes[changes.length - 1];
            vm.expectRevert(bytes("deadline has not been reached"));
            governanceProxy.executeChange(change.id);
            vm.warp(block.timestamp + delay * 1 days);
            governanceProxy.executeChange(change.id);
        }
        vm.stopPrank();
    }
}
