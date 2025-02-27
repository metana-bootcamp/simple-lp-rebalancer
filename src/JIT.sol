// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {UniswapV4ERC20} from "src/UniswapV4ERC20.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";
import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

contract JIT is BaseHook {
    // library
    using PoolIdLibrary for PoolId;
    using StateLibrary for IPoolManager;
    using SafeCast for uint128;
    using SafeCast for int128;
    using SafeCast for uint256;
    using CurrencySettler for Currency;

    // errors
    error TickSpacingNotDefault();
    error SenderMustBeHook();
    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error LiquidityDoesntMeetMinimum();
    error TooMuchSlippage();

    struct PoolInfo {
        bool hasAccruedFees;
        bool JIT;
        address liquidityToken;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    mapping(PoolId poolId => PoolInfo poolInfo) public poolInfo;

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    bytes internal constant ZERO_BYTES = bytes("");

    int256 internal constant MAX_INT = type(int256).max;

    uint16 public constant MINIMUM_LIQUIDITY = 1000;

    int24 internal constant MIN_TICK = -887220;

    int24 internal constant MAX_TICK = -MIN_TICK;

    uint16 internal constant MAX_BP = 10000; // 100%

    uint16 internal constant LARGE_SWAP_AMOUNT = 100; // 1%

    bytes32 internal constant hashSlotLowerTick =
        keccak256("hashSlotLowerTick");
    bytes32 internal constant hashSlotUpperTick =
        keccak256("hashSlotUpperTick");

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    // addLiquidity
    function addLiquidity(
        AddLiquidityParams calldata params
    ) external ensure(params.deadline) returns (uint128 liquidity) {
        // get liquidity

        // 1. get key
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
        // 2. get poolId
        PoolId poolId = key.toId();
        (
            uint160 sqrtPriceX96 /*int24 tick*/ /*uint24 protocolFee*/ /*uint24 lpFee*/,
            ,
            ,

        ) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PoolInfo storage pool = poolInfo[poolId];

        // 3. get liquidity
        uint256 poolLiquidity = poolManager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) {
            revert LiquidityDoesntMeetMinimum();
        }

        // modifying liquidity
        BalanceDelta addedDelta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            })
        );

        // mint the liquidity pool token
        if (poolLiquidity == 0) {
            liquidity -= MINIMUM_LIQUIDITY;
            UniswapV4ERC20(pool.liquidityToken).mint(
                address(0),
                MINIMUM_LIQUIDITY
            );
        }

        UniswapV4ERC20(pool.liquidityToken).mint(params.to, liquidity);

        // check for slippage
        // amount0Min < amount0Added
        // amount1Min < amount1Added
        if (
            uint128(-addedDelta.amount0()) < params.amount0Min ||
            uint128(-addedDelta.amount1()) < params.amount1Min
        ) {
            revert TooMuchSlippage();
        }
    }

    // removeLiquidty

    // UniV4-C0-C1-fee

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external override returns (bytes4) {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();

        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "UniV4",
                "-",
                ERC20(Currency.unwrap(key.currency0)).symbol(),
                "-",
                ERC20(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );

        address poolToken = address(
            new UniswapV4ERC20(tokenSymbol, tokenSymbol)
        );

        poolInfo[poolId] = PoolInfo({
            hasAccruedFees: false,
            JIT: false,
            liquidityToken: poolToken
        });

        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();
        return this.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // 1. get liquidity
        PoolId poolId = key.toId();
        (
            uint160 sqrtPriceX96,
            int24 tick /*uint24 protocolFee*/ /*uint24 lpFee*/,
            ,

        ) = poolManager.getSlot0(poolId);

        uint128 liquidity = poolManager.getLiquidity(poolId);

        {
            (uint256 amount0, uint256 amount1) = LiquidityAmounts
                .getAmountsForLiquidity(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(MIN_TICK),
                    TickMath.getSqrtPriceAtTick(MAX_TICK),
                    liquidity
                );

            // 2. determine JIT
            if (params.zeroForOne) {
                // amountSpecified * MAX_BP / amountN > LARGE_SWAP_AMOUNT
                // 2. caseA : zeroForOne
                if (params.amountSpecified < 0) {
                    poolInfo[poolId].JIT =
                        (-params.amountSpecified * int256(uint256(MAX_BP))) /
                            int256(amount0) >
                        int256(uint256(LARGE_SWAP_AMOUNT));
                } else {
                    poolInfo[poolId].JIT =
                        (params.amountSpecified * int256(uint256(MAX_BP))) /
                            int256(amount1) >
                        int256(uint256(LARGE_SWAP_AMOUNT));
                }
            } else {
                // 2. caseB : oneForZero
                if (params.amountSpecified < 0) {
                    // amountSpecified * MAX_BP / amount1 > LARGE_SWAP_AMOUNT
                    poolInfo[poolId].JIT =
                        (-params.amountSpecified * int256(uint256(MAX_BP))) /
                            int256(amount1) >
                        int256(uint256(LARGE_SWAP_AMOUNT));
                } else {
                    poolInfo[poolId].JIT =
                        (params.amountSpecified * int256(uint256(MAX_BP))) /
                            int256(amount0) >
                        int256(uint256(LARGE_SWAP_AMOUNT));
                }
            }
        }

        if (!poolInfo[poolId].JIT) {
            poolInfo[poolId].hasAccruedFees = true;
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // 3. modify liquidity
        (BalanceDelta balanceDelta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(liquidity.toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        // 4. swap
        if (!poolInfo[poolId].hasAccruedFees) {
            poolInfo[poolId].hasAccruedFees = true;
        } else {
            // sqrt price
            // amount0 / amount1
            uint160 newSqrtPriceX96 = (FixedPointMathLib.sqrt(
                FullMath.mulDiv(
                    uint256(uint128(balanceDelta.amount0())),
                    FixedPoint96.Q96,
                    uint256(uint128(balanceDelta.amount1()))
                )
            ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)).toUint160();

            sqrtPriceX96 = newSqrtPriceX96;

            // swap
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                    amountSpecified: type(int256).min,
                    sqrtPriceLimitX96: newSqrtPriceX96
                }),
                ZERO_BYTES
            );
        }

        // get nearest usable tick
        tick = _nearestUsableTick(tick, 60);
        // determine tick upper
        int24 neededupperTick = tick + key.tickSpacing;
        // determine tick lower
        int24 neededlowerTick = tick - key.tickSpacing;

        {
            assembly {
                tstore("hashSlotLowerTick", neededlowerTick)
            }
            assembly {
                tstore("hashSlotUpperTick", neededupperTick)
            }

            // 5. modify liquidity
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(neededlowerTick),
                TickMath.getSqrtPriceAtTick(neededupperTick),
                uint256(uint128(balanceDelta.amount0())),
                uint256(uint128(balanceDelta.amount1()))
            );
        }
        (BalanceDelta balanceDeltaAfter, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: neededlowerTick,
                tickUpper: neededupperTick,
                liquidityDelta: -(liquidity.toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        // 6. poolManager donate
        poolManager.donate(
            key,
            uint128(balanceDelta.amount0() + balanceDeltaAfter.amount0()),
            uint128(balanceDelta.amount1() + balanceDeltaAfter.amount1()),
            ZERO_BYTES
        );

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        PoolId poolId = key.toId();

        if (poolInfo[poolId].JIT) {
            int24 neededTickLower;
            int24 neededTickUpper;

            assembly ("memory-safe") {
                neededTickLower := tload("hashSlotLowerTick")
            }

            assembly ("memory-safe") {
                neededTickUpper := tload("hashSlotUpperTick")
            }

            rebalance(key, neededTickLower, neededTickUpper);

            PoolInfo storage pool = poolInfo[poolId];
            pool.hasAccruedFees = false;
            pool.JIT = false;
        }

        return (this.afterSwap.selector, 0);
    }

    // unlockCallback
    function _unlockCallback(
        bytes calldata rawData
    ) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            (delta, ) = poolManager.modifyLiquidity(
                data.key,
                data.params,
                ZERO_BYTES
            );
            _settleDeltas(data.sender, data.key, delta);
        }

        return abi.encode(delta);
    }

    // modify liquidity

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData(msg.sender, key, params))
            ),
            (BalanceDelta)
        );
    }

    // settle deltas
    function _settleDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        key.currency0.settle(
            poolManager,
            sender,
            uint128(-delta.amount0()),
            false
        );
        key.currency1.settle(
            poolManager,
            sender,
            uint128(-delta.amount1()),
            false
        );
    }

    // take Deltas
    function _takeDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        key.currency0.take(
            poolManager,
            sender,
            uint128(delta.amount0()),
            false
        );
        key.currency1.take(
            poolManager,
            sender,
            uint128(delta.amount1()),
            false
        );
    }

    // removeLiquidity
    function _removeLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            rebalance(key, MIN_TICK, MAX_TICK);
        }

        // (liquidityDelta * poolManage Liquidity) / pool token total supply
        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            poolManager.getLiquidity(poolId),
            UniswapV4ERC20(pool.liquidityToken).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());

        (delta, ) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    // function to get nearest usable tick
    function _nearestUsableTick(
        int24 tick_,
        uint24 tickSpacing
    ) internal pure returns (int24 result) {
        // (tick / tickSpacing) * tickSpacing
        result =
            int24(_divRound(int128(tick_), int128(int24(tickSpacing)))) *
            int24(tickSpacing);

        if (result < TickMath.MIN_TICK) {
            result += int24(tickSpacing);
        } else if (result > TickMath.MAX_TICK) {
            result -= int24(tickSpacing);
        }
    }

    function _divRound(
        int128 x,
        int128 y
    ) internal pure returns (int128 result) {
        int128 quotient = _div(x, y);
        result = quotient >> 64;

        // check if remainder is greater than 0.5
        if (quotient % 2 ** 64 >= 0x8000000000000000) {
            result += 1;
        }
    }

    int128 private constant MIN_64x64 = -0x80000000000000000000000000000000;
    int128 private constant MAX_64x64 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    function _div(int128 x, int128 y) internal pure returns (int128) {
        unchecked {
            require(y != 0);
            int256 result = (int256(x) << 64) / y;
            require(result >= MIN_64x64 && result <= MAX_64x64);
            return int128(result);
        }
    }

    // _rebalance (afterswap and remove liquidity)
    function rebalance(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper
    ) public {
        // balanceDelta =  modify liquidity
        PoolId poolId = key.toId();
        (BalanceDelta balanceDelta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );
        // calculate new price x96
        uint160 newSqrtPriceX96 = (FixedPointMathLib.sqrt(
            FullMath.mulDiv(
                uint256(uint128(balanceDelta.amount0())),
                FixedPoint96.Q96,
                uint256(uint128(balanceDelta.amount1()))
            )
        ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)).toUint160();
        // compare sqrtPricex96 from the poolManager with calculated
        (
            uint160 sqrtPriceX96,
            ,
            ,

        ) = /*uint24 protocolFee , uint24 lpFee, int24 tick*/ poolManager
                .getSlot0(poolId);
        // swap
        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: -MAX_INT - 1, // same as type(int256).min
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );
        // get liquidity given balanceDelta
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            uint256(uint128(balanceDelta.amount0())),
            uint256(uint128(balanceDelta.amount1()))
        );

        // balanceDeltaAfter =  modify liquidity
        (BalanceDelta balanceDeltaAfter, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(liquidity.toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );
        // donation
        poolManager.donate(
            key,
            uint128(balanceDelta.amount0() + balanceDeltaAfter.amount0()),
            uint128(balanceDelta.amount1() + balanceDeltaAfter.amount1()),
            ZERO_BYTES
        );
    }
}
