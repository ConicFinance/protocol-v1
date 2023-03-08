// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ICurveRegistry {
    function pool_count() external view returns (uint256);

    function pool_list(uint256 i) external view returns (address);

    function get_pool_from_lp_token(address lp_token) external view returns (address);

    function get_n_coins(address pool) external view returns (uint256[2] memory);

    function get_A(address curvePool_) external view returns (uint256);

    function get_decimals(address curvePool_) external view returns (uint256[8] memory);
}
