// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "./pools/IConicPool.sol";
import "./IOracle.sol";
import "./tokenomics/IInflationManager.sol";
import "./tokenomics/IRebalancingRewardsHandler.sol";
import "./ICurveRegistryCache.sol";

interface IController {
    event PoolAdded(address indexed pool);
    event PoolRemoved(address indexed pool);

    struct WeightUpdate {
        address conicPoolAddress;
        IConicPool.PoolWeight[] weights;
    }

    function inflationManager() external view returns (IInflationManager);

    function setInflationManager(address manager) external;

    // views
    function curveRegistryCache() external view returns (ICurveRegistryCache);

    // oracle
    function priceOracle() external view returns (IOracle);

    function setPriceOracle(address oracle) external;

    // pool functions

    function listPools() external view returns (address[] memory);

    function isPool(address poolAddress) external view returns (bool);

    function addPool(address poolAddress) external;

    function removePool(address poolAddress) external;

    function cncToken() external view returns (address);

    function lastWeightUpdate(address poolAddress) external view returns (uint256);

    function updateWeights(WeightUpdate memory update) external;

    function updateAllWeights(WeightUpdate[] memory weights) external;

    // handler functions

    function convexBooster() external view returns (address);

    function curveHandler() external view returns (address);

    function convexHandler() external view returns (address);

    function setConvexBooster(address _convexBooster) external;

    function setCurveHandler(address _curveHandler) external;

    function setConvexHandler(address _convexHandler) external;
}
