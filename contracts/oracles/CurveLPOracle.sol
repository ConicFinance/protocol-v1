// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../libraries/Types.sol";
import "../../libraries/ScaledMath.sol";
import "../../libraries/ScaledMath.sol";
import "../../libraries/CurvePoolUtils.sol";
import "../../interfaces/IOracle.sol";
import "../../interfaces/IController.sol";
import "../../interfaces/vendor/ICurveFactory.sol";
import "../../interfaces/vendor/ICurvePoolV1.sol";
import "../../interfaces/vendor/ICurvePoolV2.sol";
import "../../interfaces/vendor/ICurveMetaRegistry.sol";

contract CurveLPOracle is IOracle, Ownable {
    using ScaledMath for uint256;

    uint256 internal constant _DEFAULT_IMBALANCE_THRESHOLD = 0.02e18;
    uint256 internal constant _MAX_IMBALANCE_THRESHOLD = 0.1e18;
    mapping(address => uint256) public imbalanceThresholds;

    IOracle private immutable _genericOracle;
    IController private immutable controller;

    constructor(address genericOracle, address controller_) {
        _genericOracle = IOracle(genericOracle);
        controller = IController(controller_);
    }

    function isTokenSupported(address token) external view override returns (bool) {
        address pool = _getCurvePool(token);
        if (!controller.curveRegistryCache().isRegistered(pool)) return false;
        address[] memory coins = controller.curveRegistryCache().coins(pool);
        for (uint256 i; i < coins.length; i++) {
            address coin = coins[i];
            if (!_genericOracle.isTokenSupported(coin)) return false;
        }
        return true;
    }

    function getUSDPrice(address token) external view returns (uint256) {
        // Getting the pool data
        ICurvePoolV1 pool = ICurvePoolV1(_getCurvePool(token));
        require(controller.curveRegistryCache().isRegistered(address(pool)), "token not supported");
        uint256[] memory decimals = controller.curveRegistryCache().decimals(address(pool));

        // Adding up the USD value of all the coins in the pool
        uint256 value;
        uint256 numberOfCoins = controller.curveRegistryCache().nCoins(address(pool));
        uint256[] memory prices = new uint256[](numberOfCoins);
        uint256[] memory thresholds = new uint256[](numberOfCoins);
        for (uint256 i; i < numberOfCoins; i++) {
            address coin = pool.coins(i);
            uint256 price = _genericOracle.getUSDPrice(coin);
            prices[i] = price;
            thresholds[i] = imbalanceThresholds[token];
            require(price > 0, "price is 0");
            uint256 balance = pool.balances(i).convertScale(uint8(decimals[i]), 18);
            require(balance > 0, "balance is 0");
            value += balance.mulDown(price);
        }

        // Verifying the pool is balanced
        CurvePoolUtils.ensurePoolBalanced(
            CurvePoolUtils.PoolMeta({
                pool: address(pool),
                numberOfCoins: numberOfCoins,
                assetType: controller.curveRegistryCache().assetType(address(pool)),
                decimals: decimals,
                prices: prices,
                thresholds: thresholds
            })
        );

        // Returning the value of the pool in USD per LP Token
        return value.divDown(IERC20(token).totalSupply());
    }

    function setImbalanceThreshold(address token, uint256 threshold) external onlyOwner {
        require(threshold <= _MAX_IMBALANCE_THRESHOLD, "threshold too high");
        imbalanceThresholds[token] = threshold;
    }

    function _getCurvePool(address lpToken_) internal view returns (address) {
        address pool_ = controller.curveRegistryCache().poolFromLpToken(lpToken_);
        return pool_ == address(0) ? lpToken_ : pool_;
    }
}
