// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/pools/ILpToken.sol";
import "../interfaces/ICurveHandler.sol";
import "../interfaces/vendor/IWETH.sol";
import "../interfaces/vendor/ICurvePoolV1.sol";
import "../interfaces/vendor/ICurvePoolV1Eth.sol";
import "../interfaces/IController.sol";

/// @notice This contract acts as a wrapper for depositing and removing liquidity to and from Curve pools.
/// Please be aware of the following:
/// - This contract accepts WETH and unwraps it for Curve pool deposits
/// - This contract should only be used through delegate calls for deposits and withdrawals
/// - Slippage from deposits and withdrawals is handled in the ConicPool (do not use handler elsewhere)
contract CurveHandler is ICurveHandler {
    using SafeERC20 for IERC20;

    address internal constant _ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    IWETH internal constant _WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IController internal immutable controller;

    constructor(address controller_) {
        controller = IController(controller_);
    }

    /// @notice Deposits single sided liquidity into a Curve pool
    /// @dev This supports both v1 and v2 (crypto) pools.
    /// @param _curvePool Curve pool to deposit into
    /// @param _token Asset to deposit
    /// @param _amount Amount of asset to deposit
    function deposit(
        address _curvePool,
        address _token,
        uint256 _amount
    ) public override {
        address intermediate = controller.curveRegistryCache().basePool(_curvePool);
        if (intermediate != address(0)) {
            _addLiquidity(intermediate, _amount, _token);
            _token = controller.curveRegistryCache().lpToken(intermediate);
            _amount = ILpToken(_token).balanceOf(address(this));
        }

        _addLiquidity(_curvePool, _amount, _token);
    }

    /// @notice Withdraws single sided liquidity from a Curve pool
    /// @param _curvePool Curve pool to withdraw from
    /// @param _token Underlying asset to withdraw
    /// @param _amount Amount of Curve LP tokens to withdraw
    function withdraw(
        address _curvePool,
        address _token,
        uint256 _amount
    ) external {
        address intermediate = controller.curveRegistryCache().basePool(_curvePool);

        if (intermediate != address(0)) {
            address lpToken = controller.curveRegistryCache().lpToken(intermediate);
            _removeLiquidity(_curvePool, _amount, lpToken);
            _curvePool = intermediate;
            _amount = ILpToken(lpToken).balanceOf(address(this));
        }

        _removeLiquidity(_curvePool, _amount, _token);
    }

    function _removeLiquidity(
        address _curvePool,
        uint256 _amount, // Curve LP token amount
        address _token // underlying asset to withdraw
    ) internal {
        bool isETH = _isETH(_curvePool, _token);
        int128 index = controller.curveRegistryCache().coinIndex(
            _curvePool,
            isETH ? _ETH_ADDRESS : _token
        );

        uint256 balanceBeforeWithdraw = address(this).balance;

        ICurvePoolV1(_curvePool).remove_liquidity_one_coin(_amount, int128(int256(index)), 0);

        if (isETH) {
            uint256 balanceIncrease = address(this).balance - balanceBeforeWithdraw;
            _wrapWETH(balanceIncrease);
        }
    }

    function _wrapWETH(uint256 amount) internal {
        _WETH.deposit{value: amount}();
    }

    function _unwrapWETH(uint256 amount) internal {
        _WETH.withdraw(amount);
    }

    function _addLiquidity(
        address _curvePool,
        uint256 _amount, // amount of asset to deposit
        address _token // asset to deposit
    ) internal {
        bool isETH = _isETH(_curvePool, _token);
        if (!isETH) {
            IERC20(_token).safeIncreaseAllowance(_curvePool, _amount);
        }

        uint256 index = uint128(
            controller.curveRegistryCache().coinIndex(_curvePool, isETH ? _ETH_ADDRESS : _token)
        );
        uint256 coins = controller.curveRegistryCache().nCoins(_curvePool);
        if (coins == 2) {
            uint256[2] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else if (coins == 3) {
            uint256[3] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else if (coins == 4) {
            uint256[4] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else if (coins == 5) {
            uint256[5] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else if (coins == 6) {
            uint256[6] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else if (coins == 7) {
            uint256[7] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else if (coins == 8) {
            uint256[8] memory amounts;
            amounts[index] = _amount;
            if (isETH) {
                _unwrapWETH(_amount);
                ICurvePoolV1Eth(_curvePool).add_liquidity{value: _amount}(amounts, 0);
            } else {
                ICurvePoolV1(_curvePool).add_liquidity(amounts, 0);
            }
        } else {
            revert("invalid number of coins for curve pool");
        }
    }

    function _isETH(address pool, address token) internal view returns (bool) {
        return
            token == address(_WETH) &&
            controller.curveRegistryCache().hasCoinDirectly(pool, _ETH_ADDRESS);
    }
}
