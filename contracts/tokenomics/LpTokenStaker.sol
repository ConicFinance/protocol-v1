// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/tokenomics/ILpTokenStaker.sol";
import "../../interfaces/tokenomics/IInflationManager.sol";
import "../../interfaces/IController.sol";
import "../../interfaces/pools/IConicPool.sol";
import "../../interfaces/pools/ILpToken.sol";
import "../../interfaces/tokenomics/ICNCToken.sol";
import "../../libraries/ScaledMath.sol";

contract LpTokenStaker is ILpTokenStaker, Ownable {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILpToken;
    using ScaledMath for uint256;
    struct Boost {
        uint256 timeBoost;
        uint256 lastUpdated;
    }
    ICNCToken public constant CNC = ICNCToken(0x9aE380F0272E2162340a5bB646c354271c0F5cFC);

    uint256 public constant MAX_BOOST = 10e18;
    uint256 public constant MIN_BOOST = 1e18;
    uint256 public constant TIME_STARTING_FACTOR = 1e17;
    uint256 public constant INCREASE_PERIOD = 30 days;
    uint256 public constant TVL_FACTOR = 50e18;

    mapping(address => mapping(address => uint256)) internal stakedPerUser;
    mapping(address => uint256) public stakedPerPool;
    mapping(address => Boost) public boosts;

    mapping(address => uint256) public poolShares;
    mapping(address => uint256) public poolLastUpdated;

    IController public immutable controller;
    IInflationManager public immutable inflationManager;

    constructor(address controller_, address inflationManager_) Ownable() {
        controller = IController(controller_);
        inflationManager = IInflationManager(inflationManager_);
    }

    function stake(uint256 amount, address conicPool) external override {
        stakeFor(amount, conicPool, msg.sender);
    }

    function unstake(uint256 amount, address conicPool) external override {
        unstakeFor(amount, conicPool, msg.sender);
    }

    function stakeFor(
        uint256 amount,
        address conicPool,
        address account
    ) public override {
        require(controller.isPool(conicPool), "not a conic pool");
        uint256 exchangeRate = IConicPool(conicPool).exchangeRate();
        // Checkpoint all inflation logic
        IConicPool(conicPool).rewardManager().accountCheckpoint(account);
        _stakerCheckpoint(account, amount.mulDown(exchangeRate));
        // Actual staking
        ILpToken lpToken = IConicPool(conicPool).lpToken();
        lpToken.safeTransferFrom(msg.sender, address(this), amount);
        stakedPerUser[account][conicPool] += amount;
        stakedPerPool[conicPool] += amount;
    }

    function unstakeFor(
        uint256 amount,
        address conicPool,
        address account
    ) public override {
        require(controller.isPool(conicPool), "not a conic pool");
        require(stakedPerUser[msg.sender][conicPool] >= amount, "not enough staked");
        // Checkpoint all inflation logic
        IConicPool(conicPool).rewardManager().accountCheckpoint(account);
        _stakerCheckpoint(msg.sender, 0);
        // Actual unstaking
        ILpToken lpToken = IConicPool(conicPool).lpToken();
        stakedPerUser[msg.sender][conicPool] -= amount;
        stakedPerPool[conicPool] -= amount;
        lpToken.safeTransfer(account, amount);
    }

    function getUserBalanceForPool(address conicPool, address account)
        external
        view
        override
        returns (uint256)
    {
        return stakedPerUser[account][conicPool];
    }

    function getBalanceForPool(address conicPool) external view override returns (uint256) {
        return stakedPerPool[conicPool];
    }

    function getCachedBoost(address user) external view returns (uint256) {
        return boosts[user].timeBoost;
    }

    function getTimeToFullBoost(address user) external view returns (uint256) {
        return (ScaledMath.ONE - boosts[user].timeBoost).mulDown(INCREASE_PERIOD);
    }

    function getBoost(address user) external view override returns (uint256) {
        (uint256 userStaked, uint256 totalStaked) = _getTotalStakedForUserCommonDenomination(user);
        if (totalStaked == 0 || userStaked == 0) {
            return MIN_BOOST;
        }
        uint256 stakeBoost = ScaledMath.ONE + userStaked.divDown(totalStaked).mulDown(TVL_FACTOR);

        Boost storage userBoost = boosts[user];
        uint256 timeBoost = userBoost.timeBoost;
        timeBoost += (block.timestamp - userBoost.lastUpdated).divDown(INCREASE_PERIOD).mulDown(
            ScaledMath.ONE - TIME_STARTING_FACTOR
        );
        if (timeBoost > ScaledMath.ONE) {
            timeBoost = ScaledMath.ONE;
        }
        uint256 totalBoost = stakeBoost.mulDown(timeBoost);
        if (totalBoost < MIN_BOOST) {
            totalBoost = MIN_BOOST;
        } else if (totalBoost > MAX_BOOST) {
            totalBoost = MAX_BOOST;
        }
        return totalBoost;
    }

    function updateBoost(address user) external override {
        (uint256 userStaked, ) = _getTotalStakedForUserCommonDenomination(user);
        _updateTimeBoost(user, userStaked, 0);
    }

    function claimCNCRewardsForPool(address pool) external override {
        require(controller.isPool(pool), "not a pool");
        require(
            msg.sender == address(IConicPool(pool).rewardManager()),
            "can only be called by reward manager"
        );
        checkpoint(pool);
        uint256 cncToMint = poolShares[pool];
        if (cncToMint == 0) {
            return;
        }
        CNC.mint(address(pool), cncToMint);
        inflationManager.executeInflationRateUpdate();
        poolShares[pool] = 0;
        emit TokensClaimed(pool, cncToMint);
    }

    function claimableCnc(address pool) public view override returns (uint256) {
        uint256 currentRate = inflationManager.getCurrentPoolInflationRate(pool);
        uint256 timeElapsed = block.timestamp - poolLastUpdated[pool];
        return poolShares[pool] + (currentRate * timeElapsed);
    }

    function _stakerCheckpoint(address account, uint256 amountAdded) internal {
        (uint256 userStaked, ) = _getTotalStakedForUserCommonDenomination(account);
        _updateTimeBoost(account, userStaked, amountAdded);
    }

    function checkpoint(address pool) public override returns (uint256) {
        if (poolLastUpdated[pool] == 0) poolLastUpdated[pool] = block.timestamp;
        // Update the integral of total token supply for the pool
        uint256 timeElapsed = block.timestamp - poolLastUpdated[pool];
        if (timeElapsed == 0) return poolShares[pool];
        poolCheckpoint(pool);
        poolLastUpdated[pool] = block.timestamp;
        return poolShares[pool];
    }

    function poolCheckpoint(address pool) internal {
        uint256 currentRate = inflationManager.getCurrentPoolInflationRate(pool);
        uint256 timeElapsed = block.timestamp - poolLastUpdated[pool];
        poolShares[pool] += (currentRate * timeElapsed);
    }

    function _updateTimeBoost(
        address user,
        uint256 userStaked,
        uint256 amountAdded
    ) internal {
        Boost storage userBoost = boosts[user];

        if (userStaked == 0) {
            userBoost.timeBoost = TIME_STARTING_FACTOR;
            userBoost.lastUpdated = block.timestamp;
            return;
        }
        uint256 newBoost;
        newBoost = userBoost.timeBoost;
        newBoost += (block.timestamp - userBoost.lastUpdated).divDown(INCREASE_PERIOD).mulDown(
            ScaledMath.ONE - TIME_STARTING_FACTOR
        );
        if (newBoost > ScaledMath.ONE) {
            newBoost = ScaledMath.ONE;
        }
        if (amountAdded == 0) {
            userBoost.timeBoost = newBoost;
        } else {
            uint256 newTotalStaked = userStaked + amountAdded;
            userBoost.timeBoost =
                newBoost.mulDown(userStaked.divDown(newTotalStaked)) +
                TIME_STARTING_FACTOR.mulDown(amountAdded.divDown(newTotalStaked));
        }
        userBoost.lastUpdated = block.timestamp;
    }

    function _getTotalStakedForUserCommonDenomination(address account)
        public
        view
        returns (uint256, uint256)
    {
        address[] memory conicPools = controller.listPools();
        uint256 numPools = conicPools.length;
        uint256 totalStaked = 0;
        uint256 userStaked = 0;
        address curPool;
        uint256 curExchangeRate;
        for (uint256 i = 0; i < numPools; i++) {
            curPool = conicPools[i];
            curExchangeRate = IConicPool(curPool).exchangeRate();
            totalStaked += stakedPerPool[curPool].mulDown(curExchangeRate);
            userStaked += stakedPerUser[account][curPool].mulDown(curExchangeRate);
        }
        return (userStaked, totalStaked);
    }
}
