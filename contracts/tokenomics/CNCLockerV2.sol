// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../libraries/ScaledMath.sol";
import "../../interfaces/tokenomics/ICNCLockerV2.sol";
import "../../interfaces/tokenomics/ICNCToken.sol";
import "../../interfaces/tokenomics/ILpTokenStaker.sol";
import "../../interfaces/IController.sol";

contract CNCLockerV2 is ICNCLockerV2, Ownable {
    using SafeERC20 for ICNCToken;
    using SafeERC20 for IERC20;
    using ScaledMath for uint256;
    using ScaledMath for uint128;
    using MerkleProof for MerkleProof.Proof;

    struct VoteLock {
        uint256 amount;
        uint128 unlockTime;
        uint128 boost;
    }

    uint128 internal constant _MIN_LOCK_TIME = 120 days;
    uint128 internal constant _MAX_LOCK_TIME = 240 days;
    uint128 internal constant _GRACE_PERIOD = 30 days;
    uint128 internal constant _MIN_BOOST = 1e18;
    uint128 internal constant _MAX_BOOST = 1.5e18;
    uint128 internal constant _KICK_PENALTY = 5e16;
    uint128 constant _AIRDROP_DURATION = 182 days;

    ICNCToken public immutable cncToken;

    // Boost data
    mapping(address => uint256) public lockedBalance;
    mapping(address => uint256) public lockedBoosted;
    mapping(address => VoteLock[]) public voteLocks;
    mapping(address => uint256) public _airdroppedBoost;
    uint256 public immutable airdropEndTime;
    bytes32 public immutable merkleRoot;
    uint256 public totalLocked;
    uint256 public totalBoosted;
    bool public isShutdown;

    // Fee data
    IERC20 public immutable crv;
    IERC20 public immutable cvx;
    uint256 public accruedFeesIntegralCrv;
    uint256 public accruedFeesIntegralCvx;
    mapping(address => uint256) public perAccountAccruedCrv;
    mapping(address => uint256) public perAccountFeesCrv;
    mapping(address => uint256) public perAccountAccruedCvx;
    mapping(address => uint256) public perAccountFeesCvx;

    address public immutable treasury;
    ILpTokenStaker public immutable lpTokenStaker;
    IController public immutable controller;

    constructor(
        address _controller,
        address _cncToken,
        address _treasury,
        address _lpTokenStaker,
        address _crv,
        address _cvx,
        bytes32 _merkleRoot
    ) Ownable() {
        controller = IController(_controller);
        cncToken = ICNCToken(_cncToken);
        treasury = _treasury;
        lpTokenStaker = ILpTokenStaker(_lpTokenStaker);
        crv = IERC20(_crv);
        cvx = IERC20(_cvx);
        airdropEndTime = block.timestamp + _AIRDROP_DURATION;
        merkleRoot = _merkleRoot;
    }

    function lock(uint256 amount, uint128 lockTime) external override {
        lock(amount, lockTime, true);
    }

    /// @notice Lock an amount of CNC for vlCNC.
    /// @param amount Amount of CNC to lock.
    /// @param lockTime Duration of the lock.
    /// @param relock_ `True` if this is a relock of an existing lock.
    function lock(
        uint256 amount,
        uint128 lockTime,
        bool relock_
    ) public override {
        require(!isShutdown, "locker suspended");
        require((_MIN_LOCK_TIME <= lockTime) && (lockTime <= _MAX_LOCK_TIME), "lock time invalid");
        _feeCheckpoint(msg.sender);
        cncToken.safeTransferFrom(msg.sender, address(this), amount);

        uint128 boost = computeBoost(lockTime);

        uint256 airdropBoost_ = airdropBoost(msg.sender);
        if (airdropBoost_ > 0) {
            boost = boost.mulDownUint128(uint128(airdropBoost_));
            _airdroppedBoost[msg.sender] = 0;
        }

        uint128 unlockTime = uint128(block.timestamp) + lockTime;
        uint256 boostedAmount;

        if (relock_) {
            uint256 length = voteLocks[msg.sender].length;
            for (uint256 i = 0; i < length; i++) {
                require(
                    voteLocks[msg.sender][i].unlockTime < unlockTime,
                    "cannot move the unlock time up"
                );
            }
            delete voteLocks[msg.sender];
            totalBoosted -= lockedBoosted[msg.sender];
            lockedBoosted[msg.sender] = 0;
            voteLocks[msg.sender].push(
                VoteLock(lockedBalance[msg.sender] + amount, unlockTime, boost)
            );
            boostedAmount = (lockedBalance[msg.sender] + amount).mulDown(uint256(boost));
        } else {
            voteLocks[msg.sender].push(VoteLock(amount, unlockTime, boost));
            boostedAmount = amount.mulDown(boost);
        }
        totalLocked += amount;
        totalBoosted += boostedAmount;
        lockedBalance[msg.sender] += amount;
        lockedBoosted[msg.sender] += boostedAmount;
        emit Locked(msg.sender, amount, unlockTime, relock_);
    }

    /// @notice Process all expired locks of msg.sender and withdraw unlocked CNC.
    function executeAvailableUnlocks() external override returns (uint256) {
        _feeCheckpoint(msg.sender);
        uint256 sumUnlockable = 0;
        VoteLock[] storage _pending = voteLocks[msg.sender];
        uint256 i = _pending.length;
        while (i > 0) {
            i = i - 1;

            if (isShutdown) {
                sumUnlockable += _pending[i].amount;
                _pending[i] = _pending[_pending.length - 1];
                _pending.pop();
            } else if (_pending[i].unlockTime <= block.timestamp) {
                sumUnlockable += _pending[i].amount;
                _pending[i] = _pending[_pending.length - 1];
                _pending.pop();
            }
        }
        totalLocked -= sumUnlockable;
        lockedBalance[msg.sender] -= sumUnlockable;
        cncToken.safeTransfer(msg.sender, sumUnlockable);
        emit UnlockExecuted(msg.sender, sumUnlockable);
        return sumUnlockable;
    }

    /// @notice Get unlocked CNC balance for an address
    /// @param user Address to get unlocked CNC balance for
    /// @return Unlocked CNC balance
    function unlockableBalance(address user) public view override returns (uint256) {
        uint256 sumUnlockable = 0;
        VoteLock[] storage _pending = voteLocks[user];
        uint256 length = _pending.length;
        for (uint256 i = 0; i < length; i++) {
            if (_pending[i].unlockTime <= uint128(block.timestamp)) {
                sumUnlockable += _pending[i].amount;
            }
        }
        return sumUnlockable;
    }

    /// @notice Get unlocked boosted CNC balance for an address
    /// @param user Address to get unlocked boosted CNC balance for
    /// @return Unlocked boosted CNC balance
    function unlockableBalanceBoosted(address user) public view override returns (uint256) {
        uint256 sumUnlockable = 0;
        VoteLock[] storage _pending = voteLocks[user];
        uint256 length = _pending.length;
        for (uint256 i = 0; i < length; i++) {
            if (_pending[i].unlockTime <= uint128(block.timestamp)) {
                sumUnlockable += _pending[i].amount.mulDown(_pending[i].boost);
            }
        }
        return sumUnlockable;
    }

    function shutDown() external override onlyOwner {
        require(!isShutdown, "locker already suspended");
        isShutdown = true;
    }

    function recoverToken(address token) external override {
        require(token != address(cncToken), "cannot withdraw cnc token");
        IERC20 _token = IERC20(token);
        _token.safeTransfer(treasury, _token.balanceOf(address(this)));
    }

    /// @notice Relock a specific lock
    /// @dev Users locking CNC can create multiple locks therefore individual locks can be relocked separately.
    /// @param lockIndex Index of the lock to relock.
    /// @param lockTime Duration for which the locks's CNC amount should be relocked for.
    function relock(uint256 lockIndex, uint128 lockTime) external override {
        require(!isShutdown, "locker suspended");
        require((_MIN_LOCK_TIME <= lockTime) && (lockTime <= _MAX_LOCK_TIME), "lock time invalid");
        require(lockIndex < voteLocks[msg.sender].length, "lock doesn't exist");
        _feeCheckpoint(msg.sender);

        uint128 boost = computeBoost(lockTime);

        uint128 unlockTime = uint128(block.timestamp) + lockTime;

        VoteLock[] storage userLocks = voteLocks[msg.sender];
        require(userLocks[lockIndex].unlockTime < unlockTime, "cannot move the unlock time up");
        uint256 amount = userLocks[lockIndex].amount;
        uint256 previousBoostedAmount = userLocks[lockIndex].amount.mulDown(
            userLocks[lockIndex].boost
        );
        userLocks[lockIndex] = userLocks[userLocks.length - 1];
        userLocks.pop();

        voteLocks[msg.sender].push(VoteLock(amount, unlockTime, boost));
        uint256 boostedAmount = amount.mulDown(boost);

        totalBoosted = totalBoosted + boostedAmount - previousBoostedAmount;
        lockedBoosted[msg.sender] =
            lockedBoosted[msg.sender] +
            boostedAmount -
            previousBoostedAmount;

        emit Relocked(msg.sender, amount);
    }

    function relock(uint128 lockTime) external override {
        require(!isShutdown, "locker suspended");
        require((_MIN_LOCK_TIME <= lockTime) && (lockTime <= _MAX_LOCK_TIME), "lock time invalid");
        _feeCheckpoint(msg.sender);

        uint128 boost = computeBoost(lockTime);

        uint128 unlockTime = uint128(block.timestamp) + lockTime;

        uint256 length = voteLocks[msg.sender].length;
        for (uint256 i = 0; i < length; i++) {
            require(
                voteLocks[msg.sender][i].unlockTime < unlockTime,
                "cannot move the unlock time up"
            );
        }
        delete voteLocks[msg.sender];
        totalBoosted -= lockedBoosted[msg.sender];
        lockedBoosted[msg.sender] = 0;
        voteLocks[msg.sender].push(VoteLock(lockedBalance[msg.sender], unlockTime, boost));
        uint256 boostedAmount = lockedBalance[msg.sender].mulDown(uint256(boost));
        totalBoosted += boostedAmount;
        lockedBoosted[msg.sender] += boostedAmount;
        emit Relocked(msg.sender, lockedBalance[msg.sender]);
    }

    /// @notice Kick an expired lock
    /// @dev
    function kick(address user, uint256 lockIndex) external override {
        VoteLock[] storage _pending = voteLocks[user];
        require(lockIndex < _pending.length, "lock doesn't exist");
        require(
            _pending[lockIndex].unlockTime + _GRACE_PERIOD <= uint128(block.timestamp),
            "cannot kick this lock"
        );
        uint256 amount = _pending[lockIndex].amount;
        totalLocked -= amount;
        totalBoosted -= amount.mulDown(_pending[lockIndex].boost);
        lockedBalance[user] -= amount;
        lockedBoosted[user] -= amount.mulDown(_pending[lockIndex].boost);
        uint256 kickPenalty = amount.mulDown(_KICK_PENALTY);
        cncToken.safeTransfer(user, amount - kickPenalty);
        cncToken.safeTransfer(msg.sender, kickPenalty);
        emit KickExecuted(user, msg.sender, amount);
        _pending[lockIndex] = _pending[_pending.length - 1];
        _pending.pop();
    }

    function receiveFees(uint256 amountCrv, uint256 amountCvx) external override {
        crv.transferFrom(msg.sender, address(this), amountCrv);
        cvx.transferFrom(msg.sender, address(this), amountCvx);
        accruedFeesIntegralCrv += amountCrv.divDown(totalBoosted);
        accruedFeesIntegralCvx += amountCvx.divDown(totalBoosted);
        emit FeesReceived(msg.sender, amountCrv, amountCvx);
    }

    function claimFees() external override {
        _feeCheckpoint(msg.sender);
        uint256 crvAmount = perAccountFeesCrv[msg.sender];
        uint256 cvxAmount = perAccountFeesCvx[msg.sender];
        crv.safeTransfer(msg.sender, crvAmount);
        cvx.safeTransfer(msg.sender, cvxAmount);
        perAccountFeesCrv[msg.sender] = 0;
        perAccountFeesCvx[msg.sender] = 0;
        emit FeesClaimed(msg.sender, crvAmount, cvxAmount);
    }

    function claimAirdropBoost(
        address claimer,
        uint256 amount,
        MerkleProof.Proof calldata proof
    ) external override {
        require(block.timestamp < airdropEndTime, "airdrop ended");
        require(_airdroppedBoost[claimer] == 0, "already claimed");
        bytes32 node = keccak256(abi.encodePacked(claimer, amount));
        require(proof.isValid(node, merkleRoot), "invalid proof");
        _airdroppedBoost[claimer] = amount;
        emit AirdropBoostClaimed(claimer, amount);
    }

    function claimableFees(address account) external view returns (uint256[2] memory) {
        uint256 boost_ = totalRewardsBoost(account);
        uint256 claimableCrv = perAccountFeesCrv[account] +
            boost_.mulDown(accruedFeesIntegralCrv - perAccountAccruedCrv[account]);
        uint256 claimableCvx = perAccountFeesCvx[account] +
            boost_.mulDown(accruedFeesIntegralCvx - perAccountAccruedCvx[account]);
        return [claimableCrv, claimableCvx];
    }

    function balanceOf(address user) external view override returns (uint256) {
        return totalVoteBoost(user);
    }

    function _feeCheckpoint(address account) internal {
        uint256 boost_ = totalRewardsBoost(account);
        perAccountFeesCrv[account] += boost_.mulDown(
            accruedFeesIntegralCrv - perAccountAccruedCrv[account]
        );
        perAccountAccruedCrv[account] = accruedFeesIntegralCrv;
        perAccountFeesCvx[account] += boost_.mulDown(
            accruedFeesIntegralCvx - perAccountAccruedCvx[account]
        );
        perAccountAccruedCvx[account] = accruedFeesIntegralCvx;
    }

    function computeBoost(uint128 lockTime) public pure override returns (uint128) {
        return ((_MAX_BOOST - _MIN_BOOST).mulDownUint128(
            (lockTime - _MIN_LOCK_TIME).divDownUint128(_MAX_LOCK_TIME - _MIN_LOCK_TIME)
        ) + _MIN_BOOST);
    }

    function airdropBoost(address account) public view override returns (uint256) {
        if (_airdroppedBoost[account] == 0) return 1e18;
        return _airdroppedBoost[account];
    }

    function totalVoteBoost(address account) public view override returns (uint256) {
        return totalRewardsBoost(account).mulDown(lpTokenStaker.getBoost(account));
    }

    function totalRewardsBoost(address account) public view override returns (uint256) {
        return lockedBoosted[account] - unlockableBalanceBoosted(account);
    }
}
