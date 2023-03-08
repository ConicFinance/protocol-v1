// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IController.sol";
import "../interfaces/tokenomics/ILpTokenStaker.sol";

contract Controller is IController, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant _MAX_WEIGHT_UPDATE_MIN_DELAY = 32 days;
    uint256 internal constant _MIN_WEIGHT_UPDATE_MIN_DELAY = 1 days;

    EnumerableSet.AddressSet internal _pools;
    address public immutable cncToken;
    ICurveRegistryCache internal immutable _curveRegistryCache;

    address public override convexBooster;
    address public override curveHandler;
    address public override convexHandler;
    IOracle public override priceOracle;

    IInflationManager public override inflationManager;
    ILpTokenStaker public lpTokenStaker;

    uint256 public weightUpdateMinDelay;

    mapping(address => uint256) public lastWeightUpdate;

    constructor(address cncToken_, address curveRegistryCacheAddress_) {
        cncToken = cncToken_;
        _curveRegistryCache = ICurveRegistryCache(curveRegistryCacheAddress_);
    }

    function curveRegistryCache() external view override returns (ICurveRegistryCache) {
        return _curveRegistryCache;
    }

    function setLpTokenStaker(address _lpTokenStaker) external {
        require(address(lpTokenStaker) == address(0), "lpTokenStaker already set");
        lpTokenStaker = ILpTokenStaker(_lpTokenStaker);
    }

    function listPools() external view override returns (address[] memory) {
        return _pools.values();
    }

    function addPool(address poolAddress) external override onlyOwner {
        require(_pools.add(poolAddress), "Failed to add pool");
        lpTokenStaker.checkpoint(poolAddress);
        emit PoolAdded(poolAddress);
    }

    function removePool(address poolAddress) external override onlyOwner {
        require(_pools.remove(poolAddress), "Failed to remove pool");
        emit PoolRemoved(poolAddress);
    }

    function isPool(address poolAddress) external view override returns (bool) {
        return _pools.contains(poolAddress);
    }

    function updateWeights(WeightUpdate memory update) public override onlyOwner {
        require(
            lastWeightUpdate[update.conicPoolAddress] + weightUpdateMinDelay < block.timestamp,
            "weight update delay not elapsed"
        );
        IConicPool(update.conicPoolAddress).updateWeights(update.weights);
        lastWeightUpdate[update.conicPoolAddress] = block.timestamp;
    }

    function updateAllWeights(WeightUpdate[] memory weights) external override onlyOwner {
        for (uint256 i = 0; i < weights.length; i++) {
            updateWeights(weights[i]);
        }
    }

    function setConvexBooster(address _convexBooster) external override onlyOwner {
        convexBooster = _convexBooster;
    }

    function setCurveHandler(address _curveHandler) external override onlyOwner {
        curveHandler = _curveHandler;
    }

    function setConvexHandler(address _convexHandler) external override onlyOwner {
        convexHandler = _convexHandler;
    }

    function setInflationManager(address manager) external onlyOwner {
        inflationManager = IInflationManager(manager);
    }

    function setPriceOracle(address oracle) external override onlyOwner {
        priceOracle = IOracle(oracle);
    }

    function setWeightUpdateMinDelay(uint256 delay) external onlyOwner {
        require(delay < _MAX_WEIGHT_UPDATE_MIN_DELAY, "delay too long");
        require(delay > _MIN_WEIGHT_UPDATE_MIN_DELAY, "delay too short");
        weightUpdateMinDelay = delay;
    }

    function _isCurvePool(address _pool) internal view returns (bool) {
        return _curveRegistryCache.isRegistered(_pool);
    }
}
