// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {WadRayMath} from '@aave/core-v3/contracts/protocol/libraries/math/WadRayMath.sol';
import {PercentageMath} from '@aave/core-v3/contracts/protocol/libraries/math/PercentageMath.sol';
import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IReserveInterestRateStrategy} from '@aave/core-v3/contracts/interfaces/IReserveInterestRateStrategy.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {Errors} from '@aave/core-v3/contracts/protocol/libraries/helpers/Errors.sol';

/**
 * @title DefaultReserveInterestRateStrategy contract
 * @author Aave
 * @notice Implements the calculation of the interest rates depending on the reserve state
 * @dev The model of interest rate is based on 2 slopes, one before the `OPTIMAL_USAGE_RATIO`
 * point of usage and another from that one to 100%.
 * - An instance of this same contract, can't be used across different Aave markets, due to the caching
 *   of the PoolAddressesProvider
 **/
contract GhoInterestRateStrategy is IReserveInterestRateStrategy {
  using WadRayMath for uint256;
  using PercentageMath for uint256;

  /**
   * @dev This constant represents the usage ratio at which the pool aims to obtain most competitive borrow rates.
   * Expressed in ray
   **/
  uint256 public immutable OPTIMAL_USAGE_RATIO;

  /**
   * @dev This constant represents the optimal stable debt to total debt ratio of the reserve.
   * Expressed in ray
   */
  uint256 public immutable OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO;

  /**
   * @dev This constant represents the excess usage ratio above the optimal. It's always equal to
   * 1-optimal usage ratio. Added as a constant here for gas optimizations.
   * Expressed in ray
   **/
  uint256 public immutable MAX_EXCESS_USAGE_RATIO;

  /**
   * @dev This constant represents the excess stable debt ratio above the optimal. It's always equal to
   * 1-optimal stable to total debt ratio. Added as a constant here for gas optimizations.
   * Expressed in ray
   **/
  uint256 public immutable MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO;

  IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

  // Base variable borrow rate when usage rate = 0. Expressed in ray
  uint256 internal immutable _baseVariableBorrowRate;

  // Slope of the variable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _variableRateSlope1;

  // Slope of the variable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _variableRateSlope2;

  // Slope of the stable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _stableRateSlope1;

  // Slope of the stable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _stableRateSlope2;

  // Premium on top of `_variableRateSlope1` for base stable borrowing rate
  uint256 internal immutable _baseStableRateOffset;

  // Additional premium applied to stable rate when stable debt surpass `OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO`
  uint256 internal immutable _stableRateExcessOffset;

  /**
   * @dev Constructor.
   * @param provider The address of the PoolAddressesProvider contract
   * @param optimalUsageRatio The optimal usage ratio
   * @param baseVariableBorrowRate The base variable borrow rate
   * @param variableRateSlope1 The variable rate slope below optimal usage ratio
   * @param variableRateSlope2 The variable rate slope above optimal usage ratio
   * @param stableRateSlope1 The stable rate slope below optimal usage ratio
   * @param stableRateSlope2 The stable rate slope above optimal usage ratio
   * @param baseStableRateOffset The premium on top of variable rate for base stable borrowing rate
   * @param stableRateExcessOffset The premium on top of stable rate when there stable debt surpass the threshold
   * @param optimalStableToTotalDebtRatio The optimal stable debt to total debt ratio of the reserve
   */
  constructor(
    IPoolAddressesProvider provider,
    uint256 optimalUsageRatio,
    uint256 baseVariableBorrowRate,
    uint256 variableRateSlope1,
    uint256 variableRateSlope2,
    uint256 stableRateSlope1,
    uint256 stableRateSlope2,
    uint256 baseStableRateOffset,
    uint256 stableRateExcessOffset,
    uint256 optimalStableToTotalDebtRatio
  ) {
    require(WadRayMath.RAY >= optimalUsageRatio, Errors.INVALID_OPTIMAL_USAGE_RATIO);
    require(
      WadRayMath.RAY >= optimalStableToTotalDebtRatio,
      Errors.INVALID_OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO
    );
    OPTIMAL_USAGE_RATIO = optimalUsageRatio;
    MAX_EXCESS_USAGE_RATIO = WadRayMath.RAY - optimalUsageRatio;
    OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO = optimalStableToTotalDebtRatio;
    MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO = WadRayMath.RAY - optimalStableToTotalDebtRatio;
    ADDRESSES_PROVIDER = provider;
    _baseVariableBorrowRate = baseVariableBorrowRate;
    _variableRateSlope1 = variableRateSlope1;
    _variableRateSlope2 = variableRateSlope2;
    _stableRateSlope1 = stableRateSlope1;
    _stableRateSlope2 = stableRateSlope2;
    _baseStableRateOffset = baseStableRateOffset;
    _stableRateExcessOffset = stableRateExcessOffset;
  }

  /**
   * @notice Returns the variable rate slope below optimal usage ratio
   * @dev Its the variable rate when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO
   * @return The variable rate slope
   **/
  function getVariableRateSlope1() external view returns (uint256) {
    return _variableRateSlope1;
  }

  /**
   * @notice Returns the variable rate slope above optimal usage ratio
   * @dev Its the variable rate when usage ratio > OPTIMAL_USAGE_RATIO
   * @return The variable rate slope
   **/
  function getVariableRateSlope2() external view returns (uint256) {
    return _variableRateSlope2;
  }

  /**
   * @notice Returns the stable rate slope below optimal usage ratio
   * @dev Its the stable rate when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO
   * @return The stable rate slope
   **/
  function getStableRateSlope1() external view returns (uint256) {
    return _stableRateSlope1;
  }

  /**
   * @notice Returns the stable rate slope above optimal usage ratio
   * @dev Its the variable rate when usage ratio > OPTIMAL_USAGE_RATIO
   * @return The stable rate slope
   **/
  function getStableRateSlope2() external view returns (uint256) {
    return _stableRateSlope2;
  }

  /**
   * @notice Returns the stable rate excess offset
   * @dev An additional premium applied to the stable when stable debt > OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO
   * @return The stable rate excess offset
   */
  function getStableRateExcessOffset() external view returns (uint256) {
    return _stableRateExcessOffset;
  }

  /**
   * @notice Returns the base stable borrow rate
   * @return The base stable borrow rate
   **/
  function getBaseStableBorrowRate() public view returns (uint256) {
    return _variableRateSlope1 + _baseStableRateOffset;
  }

  /// @inheritdoc IReserveInterestRateStrategy
  function getBaseVariableBorrowRate() external view override returns (uint256) {
    return _baseVariableBorrowRate;
  }

  /// @inheritdoc IReserveInterestRateStrategy
  function getMaxVariableBorrowRate() external view override returns (uint256) {
    return _baseVariableBorrowRate + _variableRateSlope1 + _variableRateSlope2;
  }

  struct CalcInterestRatesLocalVars {
    uint256 availableLiquidity;
    uint256 totalDebt;
    uint256 currentVariableBorrowRate;
    uint256 currentStableBorrowRate;
    uint256 currentLiquidityRate;
    uint256 borrowUsageRatio;
    uint256 supplyUsageRatio;
    uint256 stableToTotalDebtRatio;
    uint256 availableLiquidityPlusDebt;
  }

  /// @inheritdoc IReserveInterestRateStrategy
  function calculateInterestRates(DataTypes.CalculateInterestRatesParams memory params)
    public
    view
    override
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    return (1e25, 1e25, _baseVariableBorrowRate);
  }
}
