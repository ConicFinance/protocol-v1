// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "../interfaces/vendor/ICurveMetaRegistry.sol";

library CurveRegistryExtensions {
    function isRegistered(ICurveMetaRegistry registry, address pool) internal view returns (bool) {
        try registry.is_registered(pool) returns (bool registered) {
            return registered;
        } catch {
            return false;
        }
    }

    function getCoins(ICurveMetaRegistry registry, address pool)
        internal
        view
        returns (address[] memory)
    {
        uint256 numCoins = registry.get_n_coins(pool);
        address[] memory coins = new address[](numCoins);
        address[8] memory staticCoins = registry.get_coins(pool);

        unchecked {
            for (uint256 i; i < numCoins; i++) {
                coins[i] = staticCoins[i];
            }
        }
        return coins;
    }

    function hasCoin(
        ICurveMetaRegistry registry,
        address pool,
        address coin
    ) internal view returns (bool) {
        address[] memory coins = getCoins(registry, pool);
        unchecked {
            for (uint256 i; i < coins.length; i++) {
                if (coins[i] == coin) {
                    return true;
                }
            }
        }
        return false;
    }

    function getCoinIndex(
        ICurveMetaRegistry registry,
        address pool,
        address coin
    ) internal view returns (int128 index) {
        address[] memory coins = getCoins(registry, pool);
        unchecked {
            for (uint256 i; i < coins.length; i++) {
                if (coins[i] == coin) {
                    return int128(uint128(i));
                }
            }
        }
        revert("coin index not found");
    }
}
