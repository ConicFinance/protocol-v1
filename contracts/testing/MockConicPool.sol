// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "../ConicPool.sol";

contract MockConicPool is ConicPool {
    // dev: gives access to LP token for testing

    bool internal _useFakeTotalUnderlying;
    uint256 internal _fakeTotalUnderlying;

    constructor(
        address _underlying,
        address _controller,
        address locker,
        string memory _lpTokenName,
        string memory _symbol,
        address _cvx,
        address _crv
    ) ConicPool(_underlying, _controller, locker, _lpTokenName, _symbol, _cvx, _crv) {}

    function balanceOf(address _account) external view returns (uint256) {
        ILpTokenStaker lpTokenStaker = controller.lpTokenStaker();
        uint256 balance = lpToken.balanceOf(_account);
        if (address(lpTokenStaker) != address(0)) {
            balance += lpTokenStaker.getUserBalanceForPool(address(this), _account);
        }
        return balance;
    }

    function totalSupply() external view returns (uint256) {
        return lpToken.totalSupply();
    }

    function name() external view returns (string memory) {
        return lpToken.name();
    }

    function symbol() public view returns (string memory) {
        return lpToken.symbol();
    }

    function decimals() public view returns (uint8) {
        return lpToken.decimals();
    }

    function mintLpTokens(address _account, uint256 _amount) external {
        mintLpTokens(_account, _amount, false);
    }

    function mintLpTokens(
        address _account,
        uint256 _amount,
        bool stake
    ) public {
        if (!stake) {
            lpToken.mint(_account, _amount);
            updateTotalUnderlying(totalUnderlying() + _amount);
        } else {
            lpToken.mint(address(this), _amount);
            IERC20(lpToken).approve(address(controller.lpTokenStaker()), _amount);
            controller.lpTokenStaker().stakeFor(_amount, address(this), _account);
            updateTotalUnderlying(totalUnderlying() + _amount);
        }
    }

    function burnLpTokens(address _account, uint256 _amount) external {
        controller.lpTokenStaker().unstake(_amount, address(this));
        lpToken.burn(_account, _amount);
        updateTotalUnderlying(totalUnderlying() - _amount);
    }

    function exchangeRate() public pure override returns (uint256) {
        return 1e18;
    }

    function usdExchangeRate() external pure override returns (uint256) {
        return 1e18;
    }

    function updateTotalUnderlying(uint256 amount) public {
        _useFakeTotalUnderlying = true;
        _fakeTotalUnderlying = amount;
    }

    function cachedTotalUnderlying() external view override returns (uint256) {
        if (_useFakeTotalUnderlying) return _fakeTotalUnderlying;
        if (block.timestamp > _cacheUpdatedTimestamp + _TOTAL_UNDERLYING_CACHE_EXPIRY) {
            return totalUnderlying();
        }
        return _cachedTotalUnderlying;
    }

    function totalUnderlying() public view override returns (uint256) {
        if (_useFakeTotalUnderlying) return _fakeTotalUnderlying;
        (uint256 totalUnderlying_, , ) = getTotalAndPerPoolUnderlying();
        return totalUnderlying_;
    }
}
