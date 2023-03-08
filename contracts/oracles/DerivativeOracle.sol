// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../../libraries/ScaledMath.sol";
import "../../libraries/CurvePoolUtils.sol";
import "../../libraries/CurveLPTokenPricing.sol";
import "../../interfaces/IOracle.sol";
import "../../interfaces/IController.sol";
import "../../interfaces/ICurveRegistryCache.sol";
import "../../interfaces/vendor/ICurvePoolV1.sol";
import "../../interfaces/vendor/ICurvePoolV2.sol";

contract DerivativeOracle is IOracle, Ownable {
    using ScaledMath for uint256;
    using CurveLPTokenPricing for ICurvePoolV1;

    uint256 internal constant _DEFAULT_IMBALANCE_THRESHOLD = 0.02e18;
    uint256 internal constant _MAX_IMBALANCE_THRESHOLD = 0.1e18;
    uint256 public imbalanceThreshold;

    IController private immutable _controller;
    IOracle private immutable _genericOracle;

    constructor(address _controller_) {
        _controller = IController(_controller_);
        _genericOracle = IOracle(IController(_controller_).priceOracle());
    }

    function isTokenSupported(address token) external view override returns (bool) {
        ICurveRegistryCache curveRegistryCache = _controller.curveRegistryCache();
        address curvePoolAddress_ = curveRegistryCache.poolFromLpToken(token);
        if (!curveRegistryCache.isRegistered(curvePoolAddress_)) {
            return false;
        }
        if (
            curveRegistryCache.assetType(curvePoolAddress_) ==
            uint256(CurvePoolUtils.AssetType.CRYPTO)
        ) {
            return false;
        }
        // this oracle does not support meta-pools
        if (curveRegistryCache.basePool(curvePoolAddress_) != address(0)) {
            return false;
        }
        return curveRegistryCache.nCoins(curvePoolAddress_) == 2;
    }

    function getUSDPrice(address token) external view returns (uint256) {
        ICurveRegistryCache curveRegistryCache = _controller.curveRegistryCache();
        ICurvePoolV1 curvePool = ICurvePoolV1(curveRegistryCache.poolFromLpToken(token));
        uint256 _numberOfCoins = curveRegistryCache.nCoins(address(curvePool));
        require(_numberOfCoins == 2, "only 2 coin pools are supported");
        uint256[] memory decimals = curveRegistryCache.decimals(address(curvePool));
        uint256 assetType = curveRegistryCache.assetType(address(curvePool));
        require(assetType != uint256(CurvePoolUtils.AssetType.CRYPTO), "crypto pool not supported");

        uint256[] memory prices = new uint256[](_numberOfCoins);
        uint256[] memory thresholds = new uint256[](_numberOfCoins);
        uint256 imbalanceThreshold_ = imbalanceThreshold;
        for (uint256 i; i < _numberOfCoins; i++) {
            address coin = curvePool.coins(i);
            uint256 price = _genericOracle.getUSDPrice(coin);
            prices[i] = price;
            thresholds[i] = imbalanceThreshold_;
            require(price > 0, "price is 0");
            uint256 balance = curvePool.balances(i).convertScale(uint8(decimals[i]), 18);
            require(balance > 0, "balance is 0");
        }

        // Verifying the pool is balanced
        CurvePoolUtils.ensurePoolBalanced(
            CurvePoolUtils.PoolMeta({
                pool: address(curvePool),
                numberOfCoins: _numberOfCoins,
                assetType: assetType,
                decimals: decimals,
                prices: prices,
                thresholds: thresholds
            })
        );

        // Returning the value of the pool in USD per LP Token
        return
            curvePool
                .getV1LpTokenPrice(prices[0].divDown(prices[1]), prices[1].divDown(prices[0]))
                .mulDown(prices[1]);
    }

    function setImbalanceThreshold(uint256 threshold) external onlyOwner {
        require(threshold <= _MAX_IMBALANCE_THRESHOLD, "threshold too high");
        imbalanceThreshold = threshold;
    }

    function _getCurvePool(address lpToken_) internal view returns (address) {
        return _controller.curveRegistryCache().poolFromLpToken(lpToken_);
    }
}
