// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/pools/IConicPool.sol";
import "../interfaces/pools/ILpToken.sol";
import "../interfaces/pools/IRewardManager.sol";
import "../interfaces/IConvexHandler.sol";
import "../interfaces/ICurveHandler.sol";
import "../interfaces/IController.sol";
import "../interfaces/tokenomics/IInflationManager.sol";
import "../interfaces/tokenomics/ILpTokenStaker.sol";
import "../interfaces/tokenomics/ICNCLockerV2.sol";
import "../interfaces/vendor/ICurvePoolV2.sol";
import "../interfaces/vendor/UniswapRouter02.sol";

import "../libraries/ScaledMath.sol";

contract RewardManager is IRewardManager, Ownable {
    using ScaledMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IERC20 public constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant CNC = IERC20(0x9aE380F0272E2162340a5bB646c354271c0F5cFC);
    UniswapRouter02 public constant SUSHISWAP =
        UniswapRouter02(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    ICurvePoolV2 public constant CNC_ETH_POOL =
        ICurvePoolV2(0x838af967537350D2C44ABB8c010E49E32673ab94);

    uint256 public constant MAX_FEE_PERCENTAGE = 3e17;

    bytes32 internal constant _CNC_KEY = "cnc";
    bytes32 internal constant _CRV_KEY = "crv";
    bytes32 internal constant _CVX_KEY = "cvx";

    address public immutable override pool;
    ILpToken public immutable lpToken;
    IERC20 public immutable underlying;
    IController public immutable controller;
    ILpTokenStaker public immutable lpTokenStaker;
    ICNCLockerV2 public immutable locker;

    uint256 public totalCRVClaimed;

    uint256 internal _oldCrvBalance;

    EnumerableSet.AddressSet internal _extraRewards;
    mapping(address => address) public extraRewardsCurvePool;
    mapping(bytes32 => RewardMeta) internal _rewardsMeta;

    bool public feesEnabled;
    uint256 public feePercentage;

    constructor(
        address _controller,
        address _pool,
        address _lpToken,
        address _underlying,
        address _lpTokenStaker,
        address cncLocker
    ) {
        pool = _pool;
        lpToken = ILpToken(_lpToken);
        underlying = IERC20(_underlying);
        controller = IController(_controller);
        lpTokenStaker = ILpTokenStaker(_lpTokenStaker);
        WETH.safeApprove(address(CNC_ETH_POOL), type(uint256).max);
        locker = ICNCLockerV2(cncLocker);
    }

    function poolCheckpoint() public override {
        IConvexHandler convexHandler = IConvexHandler(controller.convexHandler());

        (uint256 crvEarned, uint256 cvxEarned, uint256 cncEarned) = _getEarnedRewards(
            convexHandler
        );

        if (feesEnabled) {
            uint256 crvFee = crvEarned.mulDown(feePercentage);
            uint256 cvxFee = cvxEarned.mulDown(feePercentage);
            crvEarned = crvEarned - crvFee;
            cvxEarned = cvxEarned - cvxFee;
            if (crvFee > CRV.balanceOf(pool) || cvxFee > CVX.balanceOf(pool)) {
                claimPoolEarningsAndSellRewardTokens(0);
            }

            CRV.safeTransferFrom(pool, address(this), crvFee);
            CVX.safeTransferFrom(pool, address(this), cvxFee);

            // Fee transfer to the CNC locker
            CRV.approve(address(locker), crvFee);
            CVX.approve(address(locker), cvxFee);
            locker.receiveFees(crvFee, cvxFee);
        }

        uint256 _totalStaked = lpTokenStaker.getBalanceForPool(pool);
        if (_totalStaked > 0) {
            _updateEarned(_CVX_KEY, cvxEarned, _totalStaked);
            _updateEarned(_CRV_KEY, crvEarned, _totalStaked);
            _updateEarned(_CNC_KEY, cncEarned, _totalStaked);
        }
    }

    function _updateEarned(
        bytes32 key,
        uint256 earned,
        uint256 _totalSupply
    ) internal {
        _rewardsMeta[key].earnedIntegral += (earned - _rewardsMeta[key].lastEarned).divDown(
            _totalSupply
        );
        _rewardsMeta[key].lastEarned = earned;
    }

    function _getEarnedRewards()
        internal
        view
        returns (
            uint256 crvEarned,
            uint256 cvxEarned,
            uint256 cncEarned
        )
    {
        IConvexHandler convexHandler = IConvexHandler(controller.convexHandler());
        return _getEarnedRewards(convexHandler);
    }

    function _getEarnedRewards(IConvexHandler convexHandler)
        internal
        view
        returns (
            uint256 crvEarned,
            uint256 cvxEarned,
            uint256 cncEarned
        )
    {
        address[] memory curvePools = IConicPool(pool).allCurvePools();
        crvEarned =
            CRV.balanceOf(pool) -
            _oldCrvBalance +
            convexHandler.getCrvEarnedBatch(pool, curvePools);
        cvxEarned = convexHandler.computeClaimableConvex(crvEarned);
        cncEarned = lpTokenStaker.claimableCnc(pool);
    }

    function accountCheckpoint(address account) external {
        _accountCheckpoint(account);
    }

    function _accountCheckpoint(address account) internal {
        uint256 accountBalance = lpTokenStaker.getUserBalanceForPool(pool, account);
        poolCheckpoint();
        _updateAccountRewardsMeta(_CNC_KEY, account, accountBalance);
        _updateAccountRewardsMeta(_CRV_KEY, account, accountBalance);
        _updateAccountRewardsMeta(_CVX_KEY, account, accountBalance);
    }

    function _updateAccountRewardsMeta(
        bytes32 key,
        address account,
        uint256 balance
    ) internal {
        RewardMeta storage meta = _rewardsMeta[key];
        uint256 share = balance.mulDown(meta.earnedIntegral - meta.accountIntegral[account]);
        meta.accountShare[account] += share;
        meta.accountIntegral[account] = meta.earnedIntegral;
    }

    function claimEarnings()
        external
        override
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return claimEarnings(0);
    }

    /// @notice Claims all CRV, CVX and CNC earned by a user. All extra reward
    /// tokens earned will be sold for CNC.
    /// @dev Conic pool LP tokens need to be staked in the `LpTokenStaker` in
    /// order to receive a share of the CRV, CVX and CNC earnings.
    /// @param minRewardTokensCncAmount Minimum amount of CNC that should be received
    /// after selling all extra reward tokens.
    function claimEarnings(uint256 minRewardTokensCncAmount)
        public
        override
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        _accountCheckpoint(msg.sender);
        uint256 crvAmount = _rewardsMeta[_CRV_KEY].accountShare[msg.sender];
        uint256 cvxAmount = _rewardsMeta[_CVX_KEY].accountShare[msg.sender];
        uint256 cncAmount = _rewardsMeta[_CNC_KEY].accountShare[msg.sender];

        if (
            crvAmount > CRV.balanceOf(pool) ||
            cvxAmount > CVX.balanceOf(pool) ||
            cncAmount > CNC.balanceOf(pool)
        ) {
            claimPoolEarningsAndSellRewardTokens(minRewardTokensCncAmount);
            lpTokenStaker.claimCNCRewardsForPool(pool);
        }
        _rewardsMeta[_CNC_KEY].accountShare[msg.sender] = 0;
        _rewardsMeta[_CVX_KEY].accountShare[msg.sender] = 0;
        _rewardsMeta[_CRV_KEY].accountShare[msg.sender] = 0;

        CRV.safeTransferFrom(pool, msg.sender, crvAmount);
        CVX.safeTransferFrom(pool, msg.sender, cvxAmount);
        CNC.safeTransferFrom(pool, msg.sender, cncAmount);

        _oldCrvBalance = CRV.balanceOf(pool);

        emit EarningsClaimed(msg.sender, cncAmount, crvAmount, cvxAmount);
        return (cncAmount, crvAmount, cvxAmount);
    }

    /// @notice Claims all claimable CVX and CRV from Convex for all staked Curve LP tokens.
    /// Then Swaps all additional rewards tokens for CNC.
    function claimPoolEarningsAndSellRewardTokens(uint256 minRewardTokensCncAmount)
        public
        override
    {
        _claimPoolEarnings();
        _sellRewardTokens(minRewardTokensCncAmount);
    }

    /// @notice Claims all claimable CVX and CRV from Convex for all staked Curve LP tokens
    function _claimPoolEarnings() internal {
        uint256 cvxBalance = CVX.balanceOf(pool);
        uint256 crvBalance = CRV.balanceOf(pool);

        address convexHandler = controller.convexHandler();

        IConvexHandler(convexHandler).claimBatchEarnings(IConicPool(pool).allCurvePools(), pool);

        uint256 claimedCvx = CVX.balanceOf(pool) - cvxBalance;
        uint256 claimedCrv = CRV.balanceOf(pool) - crvBalance;

        totalCRVClaimed += claimedCrv;
        emit ClaimedRewards(claimedCrv, claimedCvx);
    }

    /// @notice Swaps all additional rewards tokens for CNC.
    function _sellRewardTokens(uint256 minCncAmount) internal {
        uint256 extraRewardsLength_ = _extraRewards.length();
        if (extraRewardsLength_ == 0) return;
        uint256 cncBalanceBefore_ = CNC.balanceOf(pool);
        for (uint256 i; i < extraRewardsLength_; i++) {
            _swapRewardTokenForWeth(_extraRewards.at(i));
        }
        _swapWethForCNC();

        uint256 received_ = CNC.balanceOf(pool) - cncBalanceBefore_;
        require(received_ >= minCncAmount, "received less than minCncAmount");

        uint256 _totalStaked = lpTokenStaker.getBalanceForPool(pool);
        if (_totalStaked > 0) _updateEarned(_CNC_KEY, received_, _totalStaked);
        emit SoldRewardTokens(received_);
    }

    function listExtraRewards() external view returns (address[] memory) {
        return _extraRewards.values();
    }

    function addExtraReward(address reward) public override onlyOwner returns (bool) {
        require(reward != address(0), "invalid address");
        require(
            reward != address(CVX) && reward != address(CRV) && reward != address(underlying),
            "token not allowed"
        );

        // Checking reward token isn't a Curve Pool LP Token
        address[] memory curvePools_ = IConicPool(pool).allCurvePools();
        for (uint256 i = 0; i < curvePools_.length; i++) {
            address curveLpToken_ = controller.curveRegistryCache().lpToken(curvePools_[i]);
            require(reward != curveLpToken_, "token not allowed");
        }

        IERC20(reward).safeApprove(address(SUSHISWAP), 0);
        IERC20(reward).safeApprove(address(SUSHISWAP), type(uint256).max);
        emit ExtraRewardAdded(reward);
        return _extraRewards.add(reward);
    }

    function addBatchExtraRewards(address[] memory _rewards) external override onlyOwner {
        for (uint256 i = 0; i < _rewards.length; i++) {
            addExtraReward(_rewards[i]);
        }
    }

    function removeExtraReward(address tokenAddress) external onlyOwner {
        _extraRewards.remove(tokenAddress);
        emit ExtraRewardRemoved(tokenAddress);
    }

    function setExtraRewardsCurvePool(address extraReward_, address curvePool_) external onlyOwner {
        require(curvePool_ != extraRewardsCurvePool[extraReward_], "must be different to current");
        if (curvePool_ != address(0)) {
            IERC20(extraReward_).safeApprove(curvePool_, 0);
            IERC20(extraReward_).safeApprove(curvePool_, type(uint256).max);
        }
        extraRewardsCurvePool[extraReward_] = curvePool_;
        emit ExtraRewardsCurvePoolSet(extraReward_, curvePool_);
    }

    function setFeePercentage(uint256 _feePercentage) external override onlyOwner {
        require(_feePercentage < MAX_FEE_PERCENTAGE, "cannot set fee percentage to more than 30%");
        require(locker.totalBoosted() > 0);
        feePercentage = _feePercentage;
        feesEnabled = true;
        emit FeesSet(feePercentage);
    }

    function claimableRewards(address account)
        external
        view
        returns (
            uint256 cncRewards,
            uint256 crvRewards,
            uint256 cvxRewards
        )
    {
        uint256 _totalStaked = lpTokenStaker.getBalanceForPool(pool);
        if (_totalStaked == 0) return (0, 0, 0);
        (uint256 crvEarned, uint256 cvxEarned, uint256 cncEarned) = _getEarnedRewards();
        uint256 userBalance = lpTokenStaker.getUserBalanceForPool(pool, account);

        cncRewards = _getClaimableReward(
            account,
            _CNC_KEY,
            cncEarned,
            userBalance,
            _totalStaked,
            false
        );
        crvRewards = _getClaimableReward(
            account,
            _CRV_KEY,
            crvEarned,
            userBalance,
            _totalStaked,
            feesEnabled
        );
        cvxRewards = _getClaimableReward(
            account,
            _CVX_KEY,
            cvxEarned,
            userBalance,
            _totalStaked,
            feesEnabled
        );
    }

    function _getClaimableReward(
        address account,
        bytes32 key,
        uint256 earned,
        uint256 userBalance,
        uint256 _totalSupply,
        bool deductFee
    ) internal view returns (uint256) {
        RewardMeta storage meta = _rewardsMeta[key];
        uint256 integral = meta.earnedIntegral;
        if (deductFee) {
            integral += (earned - meta.lastEarned).divDown(_totalSupply).mulDown(
                ScaledMath.ONE - feePercentage
            );
        } else {
            integral += (earned - meta.lastEarned).divDown(_totalSupply);
        }
        return
            meta.accountShare[account] +
            userBalance.mulDown(integral - meta.accountIntegral[account]);
    }

    function _swapRewardTokenForWeth(address rewardToken_) internal {
        uint256 tokenBalance_ = IERC20(rewardToken_).balanceOf(address(this));
        if (tokenBalance_ == 0) return;

        ICurvePoolV2 curvePool_ = ICurvePoolV2(extraRewardsCurvePool[rewardToken_]);
        if (address(curvePool_) != address(0)) {
            (int128 i, int128 j, ) = controller.curveRegistryCache().coinIndices(
                address(curvePool_),
                rewardToken_,
                address(WETH)
            );
            (uint256 from_, uint256 to_) = (uint256(uint128(i)), uint256(uint128(j)));
            curvePool_.exchange(from_, to_, tokenBalance_, 0, false, address(this));
            return;
        }

        address[] memory path_ = new address[](2);
        path_[0] = rewardToken_;
        path_[1] = address(WETH);
        SUSHISWAP.swapExactTokensForTokens(tokenBalance_, 0, path_, address(this), block.timestamp);
    }

    function _swapWethForCNC() internal {
        uint256 wethBalance_ = WETH.balanceOf(address(this));
        if (wethBalance_ == 0) return;
        CNC_ETH_POOL.exchange(0, 1, wethBalance_, 0, false, pool);
    }
}
