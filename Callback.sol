// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import '../../../lib/reactive-lib/src/abstract-base/AbstractCallback.sol';
import '../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import '../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol';

interface IAmmalgamPair {
    struct InputParams {
        uint128[6] totalAssets;
        uint256[6] userAssets;
        uint256 reservesXAssets;
        uint256 reservesYAssets;
        uint256 externalLiquidity;
        uint256 sqrtPriceMinInQ72;
        uint256 sqrtPriceMaxInQ72;
        uint256 activeLiquidityAssets;
        uint256 activeLiquidityScalerInQ72;
    }
    
    function getInputParams(address toCheck, bool includeLongTermPrice) 
        external view returns (InputParams memory inputParams, bool hasBorrow);
    
    function deposit(address to) external;
    function repay(address onBehalfOf) external returns (uint256, uint256);
    function repayLiquidity(address onBehalfOf) external returns (uint256, uint256, uint256);
}

// Token type constants from Ammalgam protocol
uint256 constant DEPOSIT_L = 0;
uint256 constant DEPOSIT_X = 1; 
uint256 constant DEPOSIT_Y = 2;
uint256 constant BORROW_L = 3;
uint256 constant BORROW_X = 4;
uint256 constant BORROW_Y = 5;

// Ammalgam constants
uint256 constant BIPS = 10000;
uint256 constant Q72 = 2**72;
uint256 constant Q128 = 2**128;

contract AmmalgamProtectionCallback is AbstractCallback {

    enum ProtectionType {
        COLLATERAL_ONLY,    // 0: Only deposit collateral when at risk
        DEBT_REPAYMENT_ONLY // 1: Only repay debt when at risk
    }

    enum LiquidationRisk {
        HARD_LIQUIDATION,     // LTV-based risk 
        SOFT_LIQUIDATION,     // Saturation/time-based risk  
        LEVERAGE_LIQUIDATION, // Over-leverage risk
        SAFE                  // No immediate risk
    }

    struct UserProtection {
        bool isActive;
        ProtectionType protectionType;
        uint256 healthFactorThreshold;    // When to trigger protection (e.g., 1.2e18)
        uint256 targetHealthFactor;      // Target health factor after protection (e.g., 1.5e18)
        address pairAddress;             // Ammalgam pair to protect
        address protectionAsset;         // Token to use for protection
        uint256 maxProtectionAmount;     // Max tokens to use per protection action
        uint256 lastProtectionTime;     // Timestamp of last protection (for cooldown)
        uint256 positionCreationTime;    // When position was first created
    }

    struct RiskAnalysis {
        LiquidationRisk riskType;
        uint256 currentHealthFactor;
        uint256 leverageRatio;
        uint256 borrowUtilization;
        uint256 positionAge;
        bool hasLiquidityDebt;
        bool requiresImmediateAction;
        uint256 ammalgamLTV;              // Actual Ammalgam LTV calculation
        bool wouldFailSolvency;           // Direct solvency check
        uint256 hardLiquidationPremium;   // Hard liquidation premium
        uint256 softLiquidationPremium;   // Soft liquidation premium
    }

    event UserSubscribed(
        address indexed user,
        address indexed pair,
        ProtectionType protectionType,
        uint256 healthFactorThreshold,
        uint256 targetHealthFactor
    );
    
    event UserUnsubscribed(address indexed user, address indexed pair);
    
    event ProtectionExecuted(
        address indexed user,
        address indexed pair,
        LiquidationRisk riskType,
        ProtectionType protectionType,
        uint256 amountUsed,
        uint256 oldHealthFactor,
        uint256 newHealthFactor,
        uint256 ammalgamLTV
    );
    
    event ProtectionFailed(
        address indexed user,
        address indexed pair,
        LiquidationRisk riskType,
        string reason
    );

    event ProtectionCycleCompleted(
        uint256 timestamp,
        uint256 totalUsersChecked,
        uint256 protectionsExecuted,
        uint256 protectionsFailed
    );

    // Storage
    mapping(address => mapping(address => UserProtection)) private userProtections; // user => pair => protection
    mapping(address => address[]) private userPairs; // user => pairs they're protecting
    address[] private activeUsers;
    
    // Enhanced configuration constants aligned with Ammalgam
    uint256 private constant HEALTH_FACTOR_SCALE = 1e18;
    uint256 private constant MIN_PROTECTION_INTERVAL = 300; // 5 minutes between protections
    uint256 private constant EMERGENCY_PROTECTION_INTERVAL = 60; // 1 minute for emergency
    
    // Ammalgam-specific thresholds derived from constants
    uint256 private constant MAX_LEVERAGE_SAFE = 3 * 1e18; // 3x leverage considered safe
    uint256 private constant HIGH_LEVERAGE_THRESHOLD = 5 * 1e18; // 5x leverage is high risk
    uint256 private constant OLD_POSITION_THRESHOLD = 7 days; // Position older than 7 days
    uint256 private constant HIGH_UTILIZATION_THRESHOLD = 0.8 * 1e18; // 80% utilization
    
    // LTV thresholds based on Ammalgam's liquidation constants
    uint256 private constant START_NEGATIVE_PREMIUM_LTV_BIPS = 6000; // 0.6 - from Liquidation.sol
    uint256 private constant START_PREMIUM_LTV_BIPS = 7500; // 0.75 - from Liquidation.sol
    uint256 private constant DANGER_LTV_BIPS = 9000; // 0.9 - critical threshold
    
    constructor(address _callback_sender) AbstractCallback(_callback_sender) payable {}

    // FIXED: All reactive-called functions now have address /*spender*/ as first parameter
    
    // Main periodic protection check called by reactive contract from Lasna
    function checkAndProtectPositions(
        address /*spender*/ // RSC sends address(0) for this parameter
    ) external authorizedSenderOnly {
        uint256 totalChecked = 0;
        uint256 protectionsExecuted = 0;
        uint256 protectionsFailed = 0;
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            address user = activeUsers[i];
            address[] memory pairs = userPairs[user];
            
            for (uint256 j = 0; j < pairs.length; j++) {
                address pair = pairs[j];
                UserProtection memory protection = userProtections[user][pair];
                
                if (!protection.isActive) continue;
                
                totalChecked++;

                try this._checkAndProtectUser(user, pair, protection, false) returns (bool wasProtected) {
                    if (wasProtected) {
                        protectionsExecuted++;
                    }
                } catch {
                    protectionsFailed++;
                    emit ProtectionFailed(user, pair, LiquidationRisk.SAFE, "Protection check failed");
                }
            }
        }
        
        emit ProtectionCycleCompleted(block.timestamp, totalChecked, protectionsExecuted, protectionsFailed);
    }

    // Emergency protection check for specific user (called when liquidation event detected on Sepolia)
    function emergencyProtectionCheck(
        address /*spender*/, // RSC sends address(0) for this parameter
        address user,        // Extracted from liquidation event topic_1
        address pair         // Pair contract address from log._contract
    ) external authorizedSenderOnly {
        // Check if user is subscribed to protection for this pair
        UserProtection memory protection = userProtections[user][pair];
        
        if (!protection.isActive) {
            // User not subscribed - emit completion and skip
            emit ProtectionCycleCompleted(block.timestamp, 0, 0, 0);
            return;
        }
        
        // User is subscribed - execute emergency protection
        uint256 protectionsExecuted = 0;
        uint256 protectionsFailed = 0;
        
        try this._checkAndProtectUser(user, pair, protection, true) returns (bool wasProtected) {
            if (wasProtected) {
                protectionsExecuted = 1;
            }
        } catch {
            protectionsFailed = 1;
            emit ProtectionFailed(user, pair, LiquidationRisk.SAFE, "Emergency protection failed");
        }
        
        emit ProtectionCycleCompleted(block.timestamp, 1, protectionsExecuted, protectionsFailed);
    }

    // Position change protection check for specific user (called when position events detected on Sepolia)
    function positionChangeProtectionCheck(
        address /*spender*/, // RSC sends address(0) for this parameter
        address user,        // Extracted from position change event topic_1
        address pair         // Pair contract address from log._contract
    ) external authorizedSenderOnly {
        // Check if user is subscribed to protection for this pair
        UserProtection memory protection = userProtections[user][pair];
        
        if (!protection.isActive) {
            // User not subscribed - skip
            emit ProtectionCycleCompleted(block.timestamp, 0, 0, 0);
            return;
        }
        
        // User is subscribed - check if protection needed
        uint256 protectionsExecuted = 0;
        uint256 protectionsFailed = 0;
        
        try this._checkAndProtectUser(user, pair, protection, false) returns (bool wasProtected) {
            if (wasProtected) {
                protectionsExecuted = 1;
            }
        } catch {
            protectionsFailed = 1;
            emit ProtectionFailed(user, pair, LiquidationRisk.SAFE, "Position change protection failed");
        }
        
        emit ProtectionCycleCompleted(block.timestamp, 1, protectionsExecuted, protectionsFailed);
    }

    function subscribeToProtection(
        address _pairAddress,
        ProtectionType _protectionType,
        uint256 _healthFactorThreshold,
        uint256 _targetHealthFactor,
        address _protectionAsset,
        uint256 _maxProtectionAmount
    ) external payable {
        require(_pairAddress != address(0), "Invalid pair address");
        require(_healthFactorThreshold > 1e18, "Threshold must be > 100%");
        require(_targetHealthFactor > _healthFactorThreshold, "Target must be higher than threshold");
        require(_protectionAsset != address(0), "Invalid protection asset");
        require(_maxProtectionAmount > 0, "Max amount must be > 0");

        // Verify user has a borrowing position in this pair
        (IAmmalgamPair.InputParams memory inputParams, bool hasBorrow) = 
            IAmmalgamPair(_pairAddress).getInputParams(msg.sender, false);
        require(hasBorrow, "No borrowing position found");

        UserProtection storage protection = userProtections[msg.sender][_pairAddress];
        
        // Add user to active users if first protection
        if (!protection.isActive) {
            _addUserIfNotExists(msg.sender);
            _addPairIfNotExists(msg.sender, _pairAddress);
            protection.positionCreationTime = block.timestamp;
        }

        protection.isActive = true;
        protection.protectionType = _protectionType;
        protection.healthFactorThreshold = _healthFactorThreshold;
        protection.targetHealthFactor = _targetHealthFactor;
        protection.pairAddress = _pairAddress;
        protection.protectionAsset = _protectionAsset;
        protection.maxProtectionAmount = _maxProtectionAmount;

        emit UserSubscribed(
            msg.sender, 
            _pairAddress, 
            _protectionType, 
            _healthFactorThreshold, 
            _targetHealthFactor
        );
    }

    function unsubscribeFromProtection(address _pairAddress) external {
        UserProtection storage protection = userProtections[msg.sender][_pairAddress];
        require(protection.isActive, "Not subscribed to this pair");

        protection.isActive = false;
        
        _removePairFromUser(msg.sender, _pairAddress);
        
        // Remove user if no active protections
        if (userPairs[msg.sender].length == 0) {
            _removeUserFromActive(msg.sender);
        }

        emit UserUnsubscribed(msg.sender, _pairAddress);
    }

    function _checkAndProtectUser(
        address user, 
        address pair, 
        UserProtection memory protection,
        bool isEmergency
    ) external returns (bool) {
        require(msg.sender == address(this), "Internal function only");
        
        // Check cooldown (reduced for emergency)
        uint256 cooldownPeriod = isEmergency ? EMERGENCY_PROTECTION_INTERVAL : MIN_PROTECTION_INTERVAL;
        if (block.timestamp < protection.lastProtectionTime + cooldownPeriod) {
            return false;
        }
        
        // Enhanced position analysis using Ammalgam's actual calculations
        RiskAnalysis memory analysis = _analyzePositionEnhanced(user, pair, protection);
        
        // Check if protection is needed using multiple risk indicators
        bool needsProtection = _determineIfProtectionNeeded(analysis, protection);
        
        if (!needsProtection) {
            return false;
        }
        
        // Update last protection time
        userProtections[user][pair].lastProtectionTime = block.timestamp;
        
        // Execute protection
        return _executeProtection(user, pair, protection, analysis);
    }

    function _analyzePositionEnhanced(
        address user, 
        address pair, 
        UserProtection memory protection
    ) internal view returns (RiskAnalysis memory analysis) {
        try IAmmalgamPair(pair).getInputParams(user, true) returns (
            IAmmalgamPair.InputParams memory inputParams,
            bool hasBorrow
        ) {
            if (!hasBorrow) {
                analysis.currentHealthFactor = type(uint256).max;
                analysis.riskType = LiquidationRisk.SAFE;
                return analysis;
            }

            // Enhanced position metrics using Ammalgam's actual calculations
            analysis = _calculateEnhancedMetrics(inputParams, user, pair, protection);
            
            // Determine risk type using enhanced analysis
            analysis.riskType = _determineRiskTypeEnhanced(analysis);
            
            // Critical thresholds for immediate action
            analysis.requiresImmediateAction = 
                analysis.wouldFailSolvency ||
                analysis.ammalgamLTV >= DANGER_LTV_BIPS ||
                analysis.currentHealthFactor <= (1.05 * HEALTH_FACTOR_SCALE);
            
        } catch {
            // Fallback to conservative analysis
            analysis.currentHealthFactor = 0;
            analysis.requiresImmediateAction = true;
            analysis.riskType = LiquidationRisk.HARD_LIQUIDATION;
            analysis.wouldFailSolvency = true;
        }
    }

    function _calculateEnhancedMetrics(
        IAmmalgamPair.InputParams memory inputParams,
        address user,
        address pair,
        UserProtection memory protection
    ) internal view returns (RiskAnalysis memory analysis) {
        
        // Calculate basic position metrics
        uint256 totalCollateralValue = inputParams.userAssets[DEPOSIT_L] + 
                                      inputParams.userAssets[DEPOSIT_X] + 
                                      inputParams.userAssets[DEPOSIT_Y];
        
        uint256 totalDebtValue = inputParams.userAssets[BORROW_L] + 
                                inputParams.userAssets[BORROW_X] + 
                                inputParams.userAssets[BORROW_Y];

        if (totalCollateralValue == 0) {
            analysis.currentHealthFactor = 0;
            analysis.requiresImmediateAction = true;
            analysis.wouldFailSolvency = true;
            return analysis;
        }

        // Enhanced health factor using Ammalgam's precise calculations
        analysis.currentHealthFactor = _calculatePreciseHealthFactor(inputParams);
        
        // Leverage ratio = debt / collateral  
        analysis.leverageRatio = (totalDebtValue * HEALTH_FACTOR_SCALE) / totalCollateralValue;
        
        // Borrow utilization = debt / (collateral + debt)
        uint256 totalPosition = totalCollateralValue + totalDebtValue;
        analysis.borrowUtilization = totalPosition > 0 ? 
            (totalDebtValue * HEALTH_FACTOR_SCALE) / totalPosition : 0;
        
        // Check liquidity debt composition
        analysis.hasLiquidityDebt = inputParams.userAssets[BORROW_L] > 0;
        
        // Enhanced position age calculation
        analysis.positionAge = protection.positionCreationTime > 0 ? 
            block.timestamp - protection.positionCreationTime : OLD_POSITION_THRESHOLD + 1;

        // Direct Ammalgam LTV calculation
        analysis.ammalgamLTV = _calculateAmmalgamLTV(inputParams);
        
        // Direct solvency check using Ammalgam's validation
        analysis.wouldFailSolvency = _checkAmmalgamSolvency(inputParams);
        
        // Get liquidation premiums for risk assessment
        (analysis.hardLiquidationPremium, analysis.softLiquidationPremium) = 
            _getLiquidationPremiums(inputParams, user, pair);
    }

    function _calculatePreciseHealthFactor(
        IAmmalgamPair.InputParams memory inputParams
    ) internal pure returns (uint256) {
        // Use Ammalgam's precise debt and collateral calculation
        try this._getAmmalgamDebtAndCollateral(inputParams) returns (
            uint256 netDebt, 
            uint256 netCollateral
        ) {
            if (netDebt == 0) return type(uint256).max;
            if (netCollateral == 0) return 0;
            
            // Precise health factor using Ammalgam's calculations
            return (netCollateral * HEALTH_FACTOR_SCALE) / netDebt;
            
        } catch {
            // Fallback to simple calculation if enhanced fails
            uint256 totalCollateral = inputParams.userAssets[DEPOSIT_L] + 
                                    inputParams.userAssets[DEPOSIT_X] + 
                                    inputParams.userAssets[DEPOSIT_Y];
            
            uint256 totalDebt = inputParams.userAssets[BORROW_L] + 
                               inputParams.userAssets[BORROW_X] + 
                               inputParams.userAssets[BORROW_Y];
            
            return totalDebt > 0 ? (totalCollateral * HEALTH_FACTOR_SCALE) / totalDebt : type(uint256).max;
        }
    }

    function _getAmmalgamDebtAndCollateral(
        IAmmalgamPair.InputParams memory inputParams
    ) external pure returns (uint256 netDebt, uint256 netCollateral) {
        // Implement Ammalgam's CheckLtvParams calculation
        uint256 activeLiquidityScalerInQ72 = inputParams.activeLiquidityScalerInQ72;
        
        // Convert deposits to L assets using price ranges (from Validation.sol logic)
        uint256 netDepositedXinLAssets = _convertXToL(
            inputParams.userAssets[DEPOSIT_X], 
            inputParams.sqrtPriceMaxInQ72, 
            activeLiquidityScalerInQ72
        );
        
        uint256 netDepositedYinLAssets = _convertYToL(
            inputParams.userAssets[DEPOSIT_Y], 
            inputParams.sqrtPriceMinInQ72, 
            activeLiquidityScalerInQ72
        );
        
        // Convert borrows to L assets using price ranges
        uint256 netBorrowedXinLAssets = _convertXToL(
            inputParams.userAssets[BORROW_X], 
            inputParams.sqrtPriceMinInQ72, 
            activeLiquidityScalerInQ72
        );
        
        uint256 netBorrowedYinLAssets = _convertYToL(
            inputParams.userAssets[BORROW_Y], 
            inputParams.sqrtPriceMaxInQ72, 
            activeLiquidityScalerInQ72
        );
        
        // Calculate net debt and collateral
        netCollateral = inputParams.userAssets[DEPOSIT_L] + netDepositedXinLAssets + netDepositedYinLAssets;
        netDebt = inputParams.userAssets[BORROW_L] + netBorrowedXinLAssets + netBorrowedYinLAssets;
        
        // Apply slippage adjustments for debt (conservative)
        if (inputParams.activeLiquidityAssets > inputParams.userAssets[DEPOSIT_L]) {
            uint256 availableLiquidity = inputParams.activeLiquidityAssets - inputParams.userAssets[DEPOSIT_L];
            netDebt = _increaseForSlippage(netDebt, availableLiquidity);
        }
    }

    function _convertXToL(
        uint256 xAmount, 
        uint256 sqrtPriceInQ72, 
        uint256 activeLiquidityScalerInQ72
    ) internal pure returns (uint256) {
        if (xAmount == 0) return 0;
        return (xAmount * activeLiquidityScalerInQ72) / sqrtPriceInQ72;
    }

    function _convertYToL(
        uint256 yAmount, 
        uint256 sqrtPriceInQ72, 
        uint256 activeLiquidityScalerInQ72
    ) internal pure returns (uint256) {
        if (yAmount == 0) return 0;
        return (yAmount * sqrtPriceInQ72) / activeLiquidityScalerInQ72;
    }

    function _increaseForSlippage(uint256 amount, uint256 availableLiquidity) internal pure returns (uint256) {
        if (availableLiquidity == 0) return amount;
        uint256 slippageMultiplier = 1005; // 0.5% slippage increase
        return (amount * slippageMultiplier) / 1000;
    }

    function _calculateAmmalgamLTV(
        IAmmalgamPair.InputParams memory inputParams
    ) internal view returns (uint256) {
        try this._getAmmalgamDebtAndCollateral(inputParams) returns (
            uint256 netDebt, 
            uint256 netCollateral
        ) {
            if (netCollateral == 0) return BIPS; // 100% LTV if no collateral
            return (netDebt * BIPS) / netCollateral;
        } catch {
            return 0;
        }
    }

    function _checkAmmalgamSolvency(
        IAmmalgamPair.InputParams memory inputParams
    ) internal view returns (bool wouldFailSolvency) {
        try this._getAmmalgamDebtAndCollateral(inputParams) returns (
            uint256 netDebt, 
            uint256 netCollateral
        ) {
            uint256 ltvBips = netCollateral > 0 ? (netDebt * BIPS) / netCollateral : BIPS;
            return ltvBips >= START_PREMIUM_LTV_BIPS; // 75% LTV threshold
        } catch {
            return true; // Assume failure if calculation fails
        }
    }

    function _getLiquidationPremiums(
        IAmmalgamPair.InputParams memory inputParams,
        address user,
        address pair
    ) internal view returns (uint256 hardPremium, uint256 softPremium) {
        uint256 ltvBips = _calculateAmmalgamLTV(inputParams);
        
        // Hard liquidation premium estimation
        if (ltvBips > START_NEGATIVE_PREMIUM_LTV_BIPS) {
            if (ltvBips < START_PREMIUM_LTV_BIPS) {
                hardPremium = 0;
            } else {
                hardPremium = ((ltvBips - START_PREMIUM_LTV_BIPS) * BIPS) / (DANGER_LTV_BIPS - START_PREMIUM_LTV_BIPS);
            }
        }
        
        // Soft premium estimation (time-based risk)
        UserProtection memory protection = userProtections[user][pair];
        uint256 positionAge = protection.positionCreationTime > 0 ? 
            block.timestamp - protection.positionCreationTime : 0;
        
        if (positionAge > OLD_POSITION_THRESHOLD) {
            softPremium = Math.min((positionAge * BIPS) / (30 days), BIPS);
        }
    }

    function _determineIfProtectionNeeded(
        RiskAnalysis memory analysis,
        UserProtection memory protection
    ) internal pure returns (bool) {
        // Multi-factor protection decision
        if (analysis.wouldFailSolvency) return true;
        if (analysis.ammalgamLTV >= START_NEGATIVE_PREMIUM_LTV_BIPS) return true;
        if (analysis.currentHealthFactor < protection.healthFactorThreshold) return true;
        if (analysis.hardLiquidationPremium > 0) return true;
        if (analysis.riskType == LiquidationRisk.SOFT_LIQUIDATION && analysis.softLiquidationPremium > 500) return true;
        if (analysis.riskType == LiquidationRisk.LEVERAGE_LIQUIDATION && analysis.requiresImmediateAction) return true;
        
        return false;
    }

    function _determineRiskTypeEnhanced(RiskAnalysis memory analysis) internal pure returns (LiquidationRisk) {
        // LEVERAGE risk: Very high leverage ratio OR high Ammalgam LTV
        if (analysis.leverageRatio >= HIGH_LEVERAGE_THRESHOLD || 
            analysis.ammalgamLTV >= START_PREMIUM_LTV_BIPS) {
            return LiquidationRisk.LEVERAGE_LIQUIDATION;
        }
        
        // SOFT risk: Time-based risk factors
        if (analysis.positionAge > OLD_POSITION_THRESHOLD && 
            analysis.leverageRatio > MAX_LEVERAGE_SAFE &&
            analysis.borrowUtilization > HIGH_UTILIZATION_THRESHOLD &&
            analysis.softLiquidationPremium > 0) {
            return LiquidationRisk.SOFT_LIQUIDATION;
        }
        
        // HARD risk: LTV-based or solvency risk
        if (analysis.wouldFailSolvency || 
            analysis.ammalgamLTV >= START_NEGATIVE_PREMIUM_LTV_BIPS ||
            analysis.hardLiquidationPremium > 0) {
            return LiquidationRisk.HARD_LIQUIDATION;
        }
        
        return LiquidationRisk.SAFE;
    }

    function _executeProtection(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis
    ) internal returns (bool) {
        uint256 oldHealthFactor = analysis.currentHealthFactor;
        uint256 oldLTV = analysis.ammalgamLTV;
        
        if (protection.protectionType == ProtectionType.COLLATERAL_ONLY) {
            return _executeCollateralProtection(user, pair, protection, analysis, oldHealthFactor, oldLTV);
        } else {
            return _executeDebtRepayment(user, pair, protection, analysis, oldHealthFactor, oldLTV);
        }
    }

    function _executeCollateralProtection(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis,
        uint256 oldHealthFactor,
        uint256 oldLTV
    ) internal returns (bool) {
        try this._performCollateralDeposit(user, pair, protection, analysis) 
        returns (uint256 amountUsed) {
            if (amountUsed > 0) {
                uint256 newHealthFactor = _estimateNewHealthFactorEnhanced(
                    analysis,
                    amountUsed,
                    true // adding collateral
                );
                
                emit ProtectionExecuted(
                    user, 
                    pair, 
                    analysis.riskType, 
                    protection.protectionType, 
                    amountUsed,
                    oldHealthFactor,
                    newHealthFactor,
                    oldLTV
                );
                return true;
            }
        } catch Error(string memory reason) {
            emit ProtectionFailed(user, pair, analysis.riskType, reason);
        } catch {
            emit ProtectionFailed(user, pair, analysis.riskType, "Collateral protection failed");
        }
        return false;
    }

    function _executeDebtRepayment(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis,
        uint256 oldHealthFactor,
        uint256 oldLTV
    ) internal returns (bool) {
        try this._performDebtRepayment(user, pair, protection, analysis) 
        returns (uint256 amountUsed) {
            if (amountUsed > 0) {
                uint256 newHealthFactor = _estimateNewHealthFactorEnhanced(
                    analysis,
                    amountUsed,
                    false // repaying debt
                );
                
                emit ProtectionExecuted(
                    user, 
                    pair, 
                    analysis.riskType, 
                    protection.protectionType, 
                    amountUsed,
                    oldHealthFactor,
                    newHealthFactor,
                    oldLTV
                );
                return true;
            }
        } catch Error(string memory reason) {
            emit ProtectionFailed(user, pair, analysis.riskType, reason);
        } catch {
            emit ProtectionFailed(user, pair, analysis.riskType, "Debt repayment failed");
        }
        return false;
    }

    function _performCollateralDeposit(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis
    ) external returns (uint256) {
        require(msg.sender == address(this), "Internal function only");
        
        uint256 collateralNeeded = _calculateCollateralNeededEnhanced(analysis, protection);
        uint256 actualAmount = Math.min(collateralNeeded, protection.maxProtectionAmount);
        
        if (actualAmount > 0) {
            IERC20 asset = IERC20(protection.protectionAsset);
            
            // Verify user has sufficient balance and approval
            require(asset.balanceOf(user) >= actualAmount, "Insufficient user balance");
            require(asset.allowance(user, address(this)) >= actualAmount, "Insufficient approval");
            
            // Transfer from user to this contract
            require(asset.transferFrom(user, address(this), actualAmount), "Transfer failed");
            
            // Transfer to pair and call deposit
            require(asset.transfer(pair, actualAmount), "Transfer to pair failed");
            IAmmalgamPair(pair).deposit(user);
        }
        
        return actualAmount;
    }

    function _performDebtRepayment(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis
    ) external returns (uint256) {
        require(msg.sender == address(this), "Internal function only");
        
        uint256 repaymentNeeded = _calculateRepaymentNeededEnhanced(analysis, protection);
        uint256 actualAmount = Math.min(repaymentNeeded, protection.maxProtectionAmount);
        
        if (actualAmount > 0) {
            IERC20 asset = IERC20(protection.protectionAsset);
            
            // Verify user has sufficient balance and approval
            require(asset.balanceOf(user) >= actualAmount, "Insufficient user balance");
            require(asset.allowance(user, address(this)) >= actualAmount, "Insufficient approval");
            
            // Transfer from user to this contract
            require(asset.transferFrom(user, address(this), actualAmount), "Transfer failed");
            
            // Transfer to pair and call appropriate repay function
            require(asset.transfer(pair, actualAmount), "Transfer to pair failed");
            
            // Enhanced repayment strategy based on risk type and debt composition
            if (analysis.riskType == LiquidationRisk.LEVERAGE_LIQUIDATION && analysis.hasLiquidityDebt) {
                // For leverage liquidation with liquidity debt, prioritize liquidity repayment
                IAmmalgamPair(pair).repayLiquidity(user);
            } else if (analysis.riskType == LiquidationRisk.SOFT_LIQUIDATION && analysis.hasLiquidityDebt) {
                // For soft liquidation, also prioritize liquidity repayment to reduce saturation
                IAmmalgamPair(pair).repayLiquidity(user);
            } else {
                // For hard liquidation or positions without liquidity debt, use standard repay
                IAmmalgamPair(pair).repay(user);
            }
        }
        
        return actualAmount;
    }

    function _calculateCollateralNeededEnhanced(
        RiskAnalysis memory analysis,
        UserProtection memory protection
    ) internal pure returns (uint256) {
        if (analysis.currentHealthFactor >= protection.targetHealthFactor && !analysis.wouldFailSolvency) {
            return 0;
        }
        
        uint256 baseAmount = 0;
        
        // Factor 1: Health factor deficit
        if (analysis.currentHealthFactor < protection.targetHealthFactor) {
            uint256 healthFactorDeficit = protection.targetHealthFactor - analysis.currentHealthFactor;
            baseAmount = (healthFactorDeficit * protection.maxProtectionAmount) / HEALTH_FACTOR_SCALE;
        }
        
        // Factor 2: LTV-based adjustment
        if (analysis.ammalgamLTV >= START_NEGATIVE_PREMIUM_LTV_BIPS) {
            uint256 ltvExcess = analysis.ammalgamLTV - START_NEGATIVE_PREMIUM_LTV_BIPS;
            uint256 ltvBasedAmount = (ltvExcess * protection.maxProtectionAmount) / BIPS;
            baseAmount = Math.max(baseAmount, ltvBasedAmount);
        }
        
        // Factor 3: Risk type multiplier
        if (analysis.riskType == LiquidationRisk.LEVERAGE_LIQUIDATION) {
            baseAmount = (baseAmount * 150) / 100; // 50% more for leverage risk
        } else if (analysis.riskType == LiquidationRisk.SOFT_LIQUIDATION) {
            baseAmount = (baseAmount * 125) / 100; // 25% more for soft risk
        }
        
        // Factor 4: Immediate action multiplier
        if (analysis.requiresImmediateAction) {
            baseAmount = (baseAmount * 200) / 100; // Double for immediate risk
        }
        
        return Math.min(baseAmount, protection.maxProtectionAmount);
    }

    function _calculateRepaymentNeededEnhanced(
        RiskAnalysis memory analysis,
        UserProtection memory protection
    ) internal pure returns (uint256) {
        if (analysis.currentHealthFactor >= protection.targetHealthFactor && !analysis.wouldFailSolvency) {
            return 0;
        }
        
        uint256 baseAmount = 0;
        
        // Factor 1: Health factor deficit 
        if (analysis.currentHealthFactor < protection.targetHealthFactor) {
            uint256 healthFactorDeficit = protection.targetHealthFactor - analysis.currentHealthFactor;
            baseAmount = (healthFactorDeficit * protection.maxProtectionAmount) / HEALTH_FACTOR_SCALE;
        }
        
        // Factor 2: LTV-based repayment need
        if (analysis.ammalgamLTV >= START_NEGATIVE_PREMIUM_LTV_BIPS) {
            uint256 ltvExcess = analysis.ammalgamLTV - START_NEGATIVE_PREMIUM_LTV_BIPS;
            uint256 ltvBasedAmount = (ltvExcess * protection.maxProtectionAmount) / BIPS;
            baseAmount = Math.max(baseAmount, ltvBasedAmount);
        }
        
        // Factor 3: Risk type specific adjustments
        if (analysis.riskType == LiquidationRisk.LEVERAGE_LIQUIDATION) {
            baseAmount = (baseAmount * 180) / 100; // 80% more for deleveraging
        } else if (analysis.riskType == LiquidationRisk.SOFT_LIQUIDATION) {
            baseAmount = (baseAmount * 140) / 100; // 40% more for saturation reduction
        }
        
        // Factor 4: Immediate action multiplier
        if (analysis.requiresImmediateAction || analysis.wouldFailSolvency) {
            baseAmount = (baseAmount * 250) / 100; // 2.5x for critical situations
        }
        
        return Math.min(baseAmount, protection.maxProtectionAmount);
    }

    function _estimateNewHealthFactorEnhanced(
        RiskAnalysis memory analysis,
        uint256 protectionAmount,
        bool isCollateralAddition
    ) internal pure returns (uint256) {
        if (analysis.currentHealthFactor == 0) {
            return isCollateralAddition ? HEALTH_FACTOR_SCALE / 2 : 0;
        }
        
        uint256 baseImprovement = (protectionAmount * HEALTH_FACTOR_SCALE) / 1000;
        
        // Risk-type specific improvement factors
        if (analysis.riskType == LiquidationRisk.LEVERAGE_LIQUIDATION) {
            if (!isCollateralAddition) {
                baseImprovement = (baseImprovement * 180) / 100;
            }
        } else if (analysis.riskType == LiquidationRisk.SOFT_LIQUIDATION) {
            baseImprovement = (baseImprovement * 150) / 100;
        }
        
        // LTV-based improvement scaling
        if (analysis.ammalgamLTV >= START_PREMIUM_LTV_BIPS) {
            uint256 ltvFactor = (analysis.ammalgamLTV * 150) / BIPS;
            baseImprovement = (baseImprovement * ltvFactor) / 100;
        }
        
        return analysis.currentHealthFactor + baseImprovement;
    }

    // Helper functions for user/pair management
    function _addUserIfNotExists(address user) internal {
        for (uint256 i = 0; i < activeUsers.length; i++) {
            if (activeUsers[i] == user) return;
        }
        activeUsers.push(user);
    }

    function _addPairIfNotExists(address user, address pair) internal {
        address[] storage pairs = userPairs[user];
        for (uint256 i = 0; i < pairs.length; i++) {
            if (pairs[i] == pair) return;
        }
        pairs.push(pair);
    }

    function _removePairFromUser(address user, address pair) internal {
        address[] storage pairs = userPairs[user];
        for (uint256 i = 0; i < pairs.length; i++) {
            if (pairs[i] == pair) {
                pairs[i] = pairs[pairs.length - 1];
                pairs.pop();
                break;
            }
        }
    }

    function _removeUserFromActive(address user) internal {
        for (uint256 i = 0; i < activeUsers.length; i++) {
            if (activeUsers[i] == user) {
                activeUsers[i] = activeUsers[activeUsers.length - 1];
                activeUsers.pop();
                break;
            }
        }
    }

    // View functions
    function getUserProtection(address user, address pair) external view returns (UserProtection memory) {
        return userProtections[user][pair];
    }
    
    function getUserPairs(address user) external view returns (address[] memory) {
        return userPairs[user];
    }
    
    function getActiveUsersCount() external view returns (uint256) {
        return activeUsers.length;
    }
    
    function isUserActive(address user) external view returns (bool) {
        return userPairs[user].length > 0;
    }

    function isUserSubscribedToPair(address user, address pair) external view returns (bool) {
        return userProtections[user][pair].isActive;
    }

    // Enhanced analysis functions
    function analyzeUserPosition(address user, address pair) external view returns (
        uint256 healthFactor,
        uint256 ammalgamLTV,
        LiquidationRisk riskType,
        bool wouldFailSolvency,
        uint256 hardLiquidationPremium,
        uint256 softLiquidationPremium
    ) {
        UserProtection memory protection = userProtections[user][pair];
        RiskAnalysis memory analysis = _analyzePositionEnhanced(user, pair, protection);
        
        return (
            analysis.currentHealthFactor,
            analysis.ammalgamLTV,
            analysis.riskType,
            analysis.wouldFailSolvency,
            analysis.hardLiquidationPremium,
            analysis.softLiquidationPremium
        );
    }

    function isPositionAtRisk(address user, address pair) external view returns (
        bool atRisk,
        LiquidationRisk riskType,
        string memory reason
    ) {
        UserProtection memory protection = userProtections[user][pair];
        
        if (!protection.isActive) {
            return (false, LiquidationRisk.SAFE, "User not subscribed");
        }
        
        RiskAnalysis memory analysis = _analyzePositionEnhanced(user, pair, protection);
        bool needsProtection = _determineIfProtectionNeeded(analysis, protection);
        
        string memory riskReason = "";
        if (needsProtection) {
            if (analysis.wouldFailSolvency) {
                riskReason = "Position would fail Ammalgam solvency check";
            } else if (analysis.ammalgamLTV >= START_NEGATIVE_PREMIUM_LTV_BIPS) {
                riskReason = "Ammalgam LTV exceeds threshold";
            } else if (analysis.currentHealthFactor < protection.healthFactorThreshold) {
                riskReason = "Health factor below user threshold";
            } else if (analysis.hardLiquidationPremium > 0) {
                riskReason = "Hard liquidation premium detected";
            } else if (analysis.riskType == LiquidationRisk.SOFT_LIQUIDATION) {
                riskReason = "Soft liquidation risk due to position aging";
            } else {
                riskReason = "Multiple risk factors detected";
            }
        }
        
        return (needsProtection, analysis.riskType, riskReason);
    }

    // System stats for monitoring
    function getSystemStats() external view returns (
        uint256 totalActiveUsers,
        uint256 totalActiveProtections,
        uint256 averageHealthFactor,
        uint256 usersAtRisk
    ) {
        totalActiveUsers = activeUsers.length;
        
        uint256 totalHealthFactor = 0;
        uint256 validPositions = 0;
        
        for (uint256 i = 0; i < activeUsers.length; i++) {
            address user = activeUsers[i];
            address[] memory pairs = userPairs[user];
            
            for (uint256 j = 0; j < pairs.length; j++) {
                address pair = pairs[j];
                UserProtection memory protection = userProtections[user][pair];
                
                if (protection.isActive) {
                    totalActiveProtections++;
                    
                    RiskAnalysis memory analysis = _analyzePositionEnhanced(user, pair, protection);
                    if (analysis.currentHealthFactor != type(uint256).max && analysis.currentHealthFactor > 0) {
                        totalHealthFactor += analysis.currentHealthFactor;
                        validPositions++;
                        
                        if (_determineIfProtectionNeeded(analysis, protection)) {
                            usersAtRisk++;
                        }
                    }
                }
            }
        }
        
        averageHealthFactor = validPositions > 0 ? totalHealthFactor / validPositions : 0;
    }
}
