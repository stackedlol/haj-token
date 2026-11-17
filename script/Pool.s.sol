// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {IPositionManager, IUniswapV3Factory, IUniswapV3Pool, Networks, PriceMath} from "./lib/Uniswap.sol";

/// @notice Launch step 2: opens the HAJ/WETH pool at 1% with the founder's 600,000 HAJ and POOL_ETH of ETH, full range,
///         and puts the position straight into the lock. Afterwards the founder holds 0 HAJ (any rounding dust goes
///         to the seasons lock). Reverts, spending nothing but gas, if someone opened the pool at another price first.
///
///   FOUNDER=0x… POOL_ETH=<wei> forge script script/Pool.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast
contract Pool is Script {
    function run() external returns (uint256 tokenId) {
        string memory json = vm.readFile(string.concat("deployments/", Networks.name(block.chainid), ".json"));
        tokenId = open(
            vm.envAddress("FOUNDER"),
            IERC20(vm.parseJsonAddress(json, ".token")),
            HajLPLock(vm.parseJsonAddress(json, ".lpLock")),
            vm.parseJsonAddress(json, ".seasonsVesting"),
            vm.envUint("POOL_ETH")
        );
        if (vm.envOr("WRITE_DEPLOYMENTS", true)) {
            string memory path = string.concat("deployments/", Networks.name(block.chainid), ".json");
            vm.writeJson(vm.toString(tokenId), path, ".launchPosition");
        }
    }

    struct Pair {
        address t0;
        address t1;
        uint256 a0;
        uint256 a1;
        uint160 price;
    }

    function _params(Pair memory p, address founder) internal view returns (IPositionManager.MintParams memory) {
        return IPositionManager.MintParams({
            token0: p.t0,
            token1: p.t1,
            fee: Networks.FEE,
            tickLower: Networks.FULL_LOWER,
            tickUpper: Networks.FULL_UPPER,
            amount0Desired: p.a0,
            amount1Desired: p.a1,
            amount0Min: (p.a0 * 99) / 100,
            amount1Min: (p.a1 * 99) / 100,
            recipient: founder,
            deadline: block.timestamp + 20 minutes
        });
    }

    /// @notice Mints with ETH (wrapped by the position manager), refunding any ETH it didn't need.
    function _mint(IPositionManager pm, IPositionManager.MintParams memory p, uint256 eth)
        internal
        returns (uint256 tokenId)
    {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.mint, (p));
        calls[1] = abi.encodeCall(IPositionManager.refundETH, ());
        bytes[] memory out = pm.multicall{value: eth}(calls);
        (tokenId,,,) = abi.decode(out[0], (uint256, uint128, uint256, uint256));
    }

    /// @notice HAJ and WETH in Uniswap's order (by address), with the starting price their amounts make.
    function _pair(address haj, address weth, uint256 hajAmount, uint256 eth) internal pure returns (Pair memory p) {
        (p.t0, p.t1, p.a0, p.a1) = haj < weth ? (haj, weth, hajAmount, eth) : (weth, haj, eth, hajAmount);
        p.price = PriceMath.sqrtPriceX96(p.a0, p.a1);
    }

    function open(address founder, IERC20 haj, HajLPLock lock, address seasons, uint256 eth)
        public
        returns (uint256 tokenId)
    {
        IPositionManager pm = Networks.positionManager(block.chainid);
        require(haj.balanceOf(founder) == 600_000e18, "founder should hold exactly 600,000 HAJ");
        require(eth > 0, "POOL_ETH");
        Pair memory p = _pair(address(haj), pm.WETH9(), 600_000e18, eth);

        vm.startBroadcast(founder);
        address pool = pm.createAndInitializePoolIfNecessary(p.t0, p.t1, Networks.FEE, p.price);
        (uint160 opened,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(opened == p.price, "pool already open at another price: stop and check");

        haj.approve(address(pm), 600_000e18);
        tokenId = _mint(pm, _params(p, founder), eth);
        pm.safeTransferFrom(founder, address(lock), tokenId);
        uint256 dust = haj.balanceOf(founder);
        if (dust > 0) haj.transfer(seasons, dust);
        haj.approve(address(pm), 0);
        vm.stopBroadcast();

        require(haj.balanceOf(founder) == 0, "founder should hold 0 HAJ");
        require(pm.ownerOf(tokenId) == address(lock), "position should be in the lock");
        require(IUniswapV3Factory(pm.factory()).getPool(p.t0, p.t1, Networks.FEE) == pool, "factory disagrees");
        console.log("pool", pool);
        console.log("position", tokenId, "locked until", lock.unlockAt(tokenId));
        console.log("HAJ dust sent to seasons", dust);
    }
}
