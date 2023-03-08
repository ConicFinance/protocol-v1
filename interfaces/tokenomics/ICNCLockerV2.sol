// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "../../libraries/MerkleProof.sol";

interface ICNCLockerV2 {
    event Locked(address indexed account, uint256 amount, uint256 unlockTime, bool relocked);
    event UnlockExecuted(address indexed account, uint256 amount);
    event Relocked(address indexed account, uint256 amount);
    event KickExecuted(address indexed account, address indexed kicker, uint256 amount);
    event FeesReceived(address indexed sender, uint256 crvAmount, uint256 cvxAmount);
    event FeesClaimed(address indexed claimer, uint256 crvAmount, uint256 cvxAmount);
    event AirdropBoostClaimed(address indexed claimer, uint256 amount);

    function lock(uint256 amount, uint128 lockTime) external;

    function lock(
        uint256 amount,
        uint128 lockTime,
        bool relock
    ) external;

    function relock(uint256 lockIndex, uint128 lockTime) external;

    function relock(uint128 lockTime) external;

    function totalBoosted() external view returns (uint256);

    function shutDown() external;

    function recoverToken(address token) external;

    function executeAvailableUnlocks() external returns (uint256);

    function claimAirdropBoost(
        address claimer,
        uint256 amount,
        MerkleProof.Proof calldata proof
    ) external;

    // This will need to include the boosts etc.
    function balanceOf(address user) external view returns (uint256);

    function unlockableBalance(address user) external view returns (uint256);

    function unlockableBalanceBoosted(address user) external view returns (uint256);

    function kick(address user, uint256 lockIndex) external;

    function receiveFees(uint256 amountCrv, uint256 amountCvx) external;

    function claimFees() external;

    function computeBoost(uint128 lockTime) external view returns (uint128);

    function airdropBoost(address account) external view returns (uint256);

    function totalVoteBoost(address account) external view returns (uint256);

    function totalRewardsBoost(address account) external view returns (uint256);
}
