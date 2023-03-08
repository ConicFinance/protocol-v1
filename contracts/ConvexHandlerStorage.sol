// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/vendor/ICurvePoolV1.sol";
import "../interfaces/IConvexHandlerStorage.sol";
import "../interfaces/vendor/IBooster.sol";

/// @notice this contract contains all the data that the ConvexHandler
/// might need to access
/// We store data here rather than in the ConvexHandler to avoid issues
/// when trying to delegatecall to ConvexHandler

contract ConvexHandlerStorage is Ownable, IConvexHandlerStorage {
    mapping(address => uint256) public curvePoolPid; // curve pool => convex pid
    mapping(address => bool) internal poolPidSet; // dev: used to prevent returning pid 0 for unregistered pools
    mapping(address => address) internal rewardPool; // curve pool => CRV rewards pool (convex)

    address public constant BOOSTER = address(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);

    function setCurvePoolPid(address _pool, uint256 _pid) external onlyOwner {
        require(!poolPidSet[_pool], "pool pid already set");
        curvePoolPid[_pool] = _pid;
        poolPidSet[_pool] = true;
        (, , , address _rewardPool, , ) = IBooster(BOOSTER).poolInfo(_pid);
        require(_rewardPool != address(0), "convex crv reward pool does not exist");
        rewardPool[_pool] = _rewardPool;
    }

    function getPid(address _pool) external view returns (uint256) {
        require(poolPidSet[_pool], "pool has not been added");
        return curvePoolPid[_pool];
    }

    function getRewardPool(address _pool) external view returns (address) {
        return rewardPool[_pool];
    }
}
