// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

interface IConvexHandlerStorage {
    function setCurvePoolPid(address _pool, uint256 _pid) external;

    function getPid(address _pool) external view returns (uint256);

    function getRewardPool(address _pool) external view returns (address);
}
