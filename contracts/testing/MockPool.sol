// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/pools/IConicPool.sol";
import "../../interfaces/tokenomics/IInflationManager.sol";
import "../../interfaces/tokenomics/ILpTokenStaker.sol";
import "../LpToken.sol";

contract MockRewardManager is IRewardManager {
    address public immutable override pool;

    constructor(address _pool) {
        pool = _pool;
    }

    function accountCheckpoint(address account) external {}

    function poolCheckpoint() external pure returns (bool) {
        return true;
    }

    function addExtraReward(address reward) external returns (bool) {}

    function addBatchExtraRewards(address[] memory rewards) external {}

    function setFeePercentage(
        uint256 // _feePercentage
    ) external pure {
        require(0 == 1, "wrong contract");
    }

    function claimableRewards(address account)
        external
        view
        returns (
            uint256 cncRewards,
            uint256 crvRewards,
            uint256 cvxRewards
        )
    {}

    function claimEarnings()
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {}

    function claimPoolEarnings() external {}

    function sellRewardTokens() external {}

    function claimPoolEarningsAndSellRewardTokens() external {}
}

contract MockPool is IConicPool {
    IRewardManager public immutable rewardManager;
    ILpToken public immutable override lpToken;
    IInflationManager private immutable _inflationManager;
    ILpTokenStaker private immutable lpTokenStaker;

    bool internal _useFakeTotalUnderlying;
    uint256 internal _fakeTotalUnderlying;

    IERC20Metadata public override underlying;

    constructor(
        address inflationManager,
        address _underlying,
        address _lpTokenStaker
    ) {
        underlying = IERC20Metadata(_underlying);
        rewardManager = new MockRewardManager(address(this));
        lpToken = new LpToken(address(this), 18, "TEST", "TEST");
        _inflationManager = IInflationManager(inflationManager);
        lpTokenStaker = ILpTokenStaker(_lpTokenStaker);
    }

    function depositFor(
        address _account,
        uint256 _amount,
        uint256 _minLpReceived,
        bool stake
    ) external returns (uint256) {}

    function deposit(uint256 _amount, uint256 _minLpReceived) external returns (uint256) {}

    function deposit(
        uint256 _amount,
        uint256 _minLpReceived,
        bool stake
    ) external returns (uint256) {}

    function exchangeRate() external view returns (uint256) {}

    function allCurvePools() external view returns (address[] memory) {}

    function curveLpOracle() external view returns (IOracle) {}

    function tokenOracle() external view returns (IOracle) {}

    function claimPoolEarnings() external {}

    function handleInvalidConvexPid(address pool) external {}

    function withdraw(uint256 _amount, uint256 _minAmount) external returns (uint256) {}

    function updateWeights(PoolWeight[] memory poolWeights) external {}

    function getWeights() external pure override returns (PoolWeight[] memory) {
        PoolWeight[] memory value_;
        return value_;
    }

    function getAllocatedUnderlying() external pure override returns (PoolWithAmount[] memory) {
        PoolWithAmount[] memory value_;
        return value_;
    }

    function rebalance() external {}

    function updateTotalUnderlying(uint256 amount) public {
        _useFakeTotalUnderlying = true;
        _fakeTotalUnderlying = amount;
    }

    function cachedTotalUnderlying() external view returns (uint256) {
        return _fakeTotalUnderlying;
    }

    function rebalancingRewardActive() external view returns (bool) {}

    function totalUnderlying() public view returns (uint256) {
        return _fakeTotalUnderlying;
    }

    function mintLPTokens(address _account, uint256 _amount) external {
        mintLPTokens(_account, _amount, false);
    }

    function mintLPTokens(
        address _account,
        uint256 _amount,
        bool stake
    ) public {
        if (!stake) {
            lpToken.mint(_account, _amount);
            updateTotalUnderlying(totalUnderlying() + _amount);
        } else {
            lpToken.mint(address(this), _amount);
            IERC20(lpToken).approve(address(lpTokenStaker), _amount);
            lpTokenStaker.stakeFor(_amount, address(this), _account);
            updateTotalUnderlying(totalUnderlying() + _amount);
        }
    }

    function burnLPTokens(address _account, uint256 _amount) external {
        lpTokenStaker.unstake(_amount, address(this));
        lpToken.burn(_account, _amount);
        updateTotalUnderlying(totalUnderlying() - _amount);
    }

    function computeTotalDeviation() external pure returns (uint256) {
        return 0;
    }

    function totalDeviationAfterWeightUpdate() external pure returns (uint256) {
        return 0;
    }

    function removeCurvePool(address pool) external {}

    function addCurvePool(address pool) external {}

    function usdExchangeRate() external view override returns (uint256) {
        return 1e18;
    }
}
