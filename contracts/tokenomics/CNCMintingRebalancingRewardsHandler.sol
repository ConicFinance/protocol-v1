// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../../interfaces/tokenomics/IRebalancingRewardsHandler.sol";
import "../../interfaces/tokenomics/IInflationManager.sol";
import "../../interfaces/tokenomics/ICNCToken.sol";
import "../../interfaces/IController.sol";
import "../../interfaces/pools/IConicPool.sol";
import "../../libraries/ScaledMath.sol";

contract CNCMintingRebalancingRewardsHandler is IRebalancingRewardsHandler, Ownable {
    using ScaledMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    event SetCncRebalancingRewardPerDollarPerSecond(uint256 cncRebalancingRewardPerDollarPerSecond);

    /// @dev gives out 1 dollar per 6 hours (assuming 1 CNC = 5 USD) for every 10,000 USD of TVL
    uint256 internal constant _INITIAL_REBALANCING_REWARD_PER_DOLLAR_PER_SECOND =
        1e18 / uint256(3600 * 6 * 10_000 * 5);

    /// @dev to avoid CNC rewards being too low, the TVL is assumed to be at least 100k
    /// when computing the rebalancing rewards
    uint256 internal constant _MIN_REBALANCING_REWARD_DOLAR_MULTIPLIER = 100_000e18;

    /// @dev to avoid CNC rewards being too high, the TVL is assumed to be at most 10m
    /// when computing the rebalancing rewards
    uint256 internal constant _MAX_REBALANCING_REWARD_DOLAR_MULTIPLIER = 10_000_000e18;

    ICNCToken public immutable cnc;
    IController public immutable controller;

    uint256 public cncRebalancingRewardPerDollarPerSecond;

    modifier onlyInflationManager() {
        require(
            msg.sender == address(controller.inflationManager()),
            "only InflationManager can call this function"
        );
        _;
    }

    constructor(IController _controller, ICNCToken _cnc) {
        cncRebalancingRewardPerDollarPerSecond = _INITIAL_REBALANCING_REWARD_PER_DOLLAR_PER_SECOND;
        controller = _controller;
        cnc = _cnc;
    }

    function setCncRebalancingRewardPerDollarPerSecond(
        uint256 _cncRebalancingRewardPerDollarPerSecond
    ) external onlyOwner {
        cncRebalancingRewardPerDollarPerSecond = _cncRebalancingRewardPerDollarPerSecond;
        emit SetCncRebalancingRewardPerDollarPerSecond(_cncRebalancingRewardPerDollarPerSecond);
    }

    function distributeRebalancingRewards(
        address pool,
        address account,
        uint256 amount
    ) internal {
        uint256 mintedAmount = cnc.mint(account, amount);
        if (mintedAmount > 0) {
            emit RebalancingRewardDistributed(pool, account, address(cnc), mintedAmount);
        }
    }

    function poolCNCRebalancingRewardPerSecond(address pool) public view returns (uint256) {
        (uint256 poolWeight, uint256 totalUSDValue) = controller
            .inflationManager()
            .computePoolWeight(pool);
        uint256 tvlMultiplier = totalUSDValue;
        if (tvlMultiplier < _MIN_REBALANCING_REWARD_DOLAR_MULTIPLIER)
            tvlMultiplier = _MIN_REBALANCING_REWARD_DOLAR_MULTIPLIER;
        if (tvlMultiplier > _MAX_REBALANCING_REWARD_DOLAR_MULTIPLIER)
            tvlMultiplier = _MAX_REBALANCING_REWARD_DOLAR_MULTIPLIER;
        return cncRebalancingRewardPerDollarPerSecond.mulDown(poolWeight).mulDown(tvlMultiplier);
    }

    function handleRebalancingRewards(
        IConicPool conicPool,
        address account,
        uint256 deviationBefore,
        uint256 deviationAfter
    ) external onlyInflationManager {
        uint256 cncPerSecond = poolCNCRebalancingRewardPerSecond(address(conicPool));
        uint256 cncRewardAmount = _computeRebalancingRewards(
            conicPool,
            deviationBefore,
            deviationAfter,
            cncPerSecond
        );
        distributeRebalancingRewards(address(conicPool), account, cncRewardAmount);
    }

    /// @dev this computes how much CNC a user should get when depositing
    /// this does not check whether the rewards should still be distributed
    /// amount CNC = t * CNC/s * (1 - (Δdeviation / initialDeviation))
    /// where
    /// CNC/s: the amount of CNC per second to distributed for rebalancing
    /// t: the time elapsed since the weight update
    /// Δdeviation: the deviation difference caused by this deposit
    /// initialDeviation: the deviation after updating weights
    /// @return the amount of CNC to give to the user as reward
    function _computeRebalancingRewards(
        IConicPool conicPool,
        uint256 deviationBefore,
        uint256 deviationAfter,
        uint256 cncPerSecond
    ) internal view returns (uint256) {
        if (deviationBefore < deviationAfter) return 0;
        uint256 deviationDelta = deviationBefore - deviationAfter;
        uint256 deviationImprovementRatio = deviationDelta.divDown(
            conicPool.totalDeviationAfterWeightUpdate()
        );
        uint256 lastWeightUpdate = controller.lastWeightUpdate(address(conicPool));
        uint256 elapsedSinceUpdate = uint256(block.timestamp) - lastWeightUpdate;
        return (elapsedSinceUpdate * cncPerSecond).mulDown(deviationImprovementRatio);
    }
}
