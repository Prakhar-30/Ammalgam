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
    }

    struct RiskAnalysis {
        LiquidationRisk riskType;
        uint256 currentHealthFactor;
        uint256 leverageRatio;
        uint256 borrowUtilization;
        uint256 positionAge;
        bool hasLiquidityDebt;
        bool requiresImmediateAction;
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
        uint256 newHealthFactor
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
    
    // Configuration constants
    uint256 private constant HEALTH_FACTOR_SCALE = 1e18;
    uint256 private constant MIN_PROTECTION_INTERVAL = 300; // 5 minutes between protections
    uint256 private constant EMERGENCY_PROTECTION_INTERVAL = 60; // 1 minute for emergency
    uint256 private constant MAX_LEVERAGE_SAFE = 3 * 1e18; // 3x leverage considered safe
    uint256 private constant HIGH_LEVERAGE_THRESHOLD = 5 * 1e18; // 5x leverage is high risk
    uint256 private constant OLD_POSITION_THRESHOLD = 7 days; // Position older than 7 days
    uint256 private constant HIGH_UTILIZATION_THRESHOLD = 0.8 * 1e18; // 80% utilization
    
    constructor(address _callback_sender) AbstractCallback(_callback_sender) payable {}

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

    // Main periodic protection check called by reactive contract
    function checkAndProtectPositions(address /* sender */) external authorizedSenderOnly {
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

    // Emergency protection check for specific user (called when liquidation event detected)
    function emergencyProtectionCheck(address user, address pair) external authorizedSenderOnly {
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

    // Position change protection check for specific user  
    function positionChangeProtectionCheck(address user, address pair) external authorizedSenderOnly {
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
        
        // Analyze position risk
        RiskAnalysis memory analysis = _analyzePosition(user, pair);
        
        // Check if protection is needed
        if (analysis.currentHealthFactor >= protection.healthFactorThreshold && !analysis.requiresImmediateAction) {
            return false;
        }
        
        // Update last protection time
        userProtections[user][pair].lastProtectionTime = block.timestamp;
        
        // Execute protection
        return _executeProtection(user, pair, protection, analysis);
    }

    function _analyzePosition(address user, address pair) internal view returns (RiskAnalysis memory analysis) {
        try IAmmalgamPair(pair).getInputParams(user, true) returns (
            IAmmalgamPair.InputParams memory inputParams,
            bool hasBorrow
        ) {
            if (!hasBorrow) {
                analysis.currentHealthFactor = type(uint256).max;
                analysis.riskType = LiquidationRisk.SAFE;
                return analysis;
            }

            // Calculate position metrics
            uint256 totalCollateralValue = inputParams.userAssets[DEPOSIT_L] + 
                                          inputParams.userAssets[DEPOSIT_X] + 
                                          inputParams.userAssets[DEPOSIT_Y];
            
            uint256 totalDebtValue = inputParams.userAssets[BORROW_L] + 
                                    inputParams.userAssets[BORROW_X] + 
                                    inputParams.userAssets[BORROW_Y];

            if (totalCollateralValue == 0) {
                analysis.currentHealthFactor = 0;
                analysis.requiresImmediateAction = true;
                analysis.riskType = LiquidationRisk.HARD_LIQUIDATION;
                return analysis;
            }

            // Health factor = collateral / debt
            analysis.currentHealthFactor = (totalCollateralValue * HEALTH_FACTOR_SCALE) / totalDebtValue;
            
            // Leverage ratio = debt / collateral  
            analysis.leverageRatio = (totalDebtValue * HEALTH_FACTOR_SCALE) / totalCollateralValue;
            
            // Borrow utilization = debt / (collateral + debt)
            uint256 totalPosition = totalCollateralValue + totalDebtValue;
            analysis.borrowUtilization = totalPosition > 0 ? 
                (totalDebtValue * HEALTH_FACTOR_SCALE) / totalPosition : 0;
            
            // Check if position has liquidity debt
            analysis.hasLiquidityDebt = inputParams.userAssets[BORROW_L] > 0;
            
            // Position age estimation
            UserProtection memory protection = userProtections[user][pair];
            analysis.positionAge = protection.lastProtectionTime > 0 ? 
                block.timestamp - protection.lastProtectionTime : OLD_POSITION_THRESHOLD + 1;

            // Determine risk type
            analysis.riskType = _determineRiskType(analysis);
            analysis.requiresImmediateAction = analysis.currentHealthFactor <= (1.05 * HEALTH_FACTOR_SCALE); // Below 105%
            
        } catch {
            analysis.currentHealthFactor = 0;
            analysis.requiresImmediateAction = true;
            analysis.riskType = LiquidationRisk.HARD_LIQUIDATION;
        }
    }

    function _determineRiskType(RiskAnalysis memory analysis) internal pure returns (LiquidationRisk) {
        // LEVERAGE risk: Very high leverage ratio
        if (analysis.leverageRatio >= HIGH_LEVERAGE_THRESHOLD) {
            return LiquidationRisk.LEVERAGE_LIQUIDATION;
        }
        
        // SOFT risk: Old position with moderate leverage and high utilization
        if (analysis.positionAge > OLD_POSITION_THRESHOLD && 
            analysis.leverageRatio > MAX_LEVERAGE_SAFE &&
            analysis.borrowUtilization > HIGH_UTILIZATION_THRESHOLD) {
            return LiquidationRisk.SOFT_LIQUIDATION;
        }
        
        // HARD risk: Standard LTV/health factor based liquidation risk
        return LiquidationRisk.HARD_LIQUIDATION;
    }

    function _executeProtection(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis
    ) internal returns (bool) {
        uint256 oldHealthFactor = analysis.currentHealthFactor;
        
        if (protection.protectionType == ProtectionType.COLLATERAL_ONLY) {
            return _executeCollateralProtection(user, pair, protection, analysis, oldHealthFactor);
        } else {
            return _executeDebtRepayment(user, pair, protection, analysis, oldHealthFactor);
        }
    }

    function _executeCollateralProtection(
        address user,
        address pair,
        UserProtection memory protection,
        RiskAnalysis memory analysis,
        uint256 oldHealthFactor
    ) internal returns (bool) {
        try this._performCollateralDeposit(user, pair, protection, analysis) 
        returns (uint256 amountUsed) {
            if (amountUsed > 0) {
                uint256 newHealthFactor = _estimateNewHealthFactor(
                    analysis.currentHealthFactor,
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
                    newHealthFactor
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
        uint256 oldHealthFactor
    ) internal returns (bool) {
        try this._performDebtRepayment(user, pair, protection, analysis) 
        returns (uint256 amountUsed) {
            if (amountUsed > 0) {
                uint256 newHealthFactor = _estimateNewHealthFactor(
                    analysis.currentHealthFactor,
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
                    newHealthFactor
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
        
        uint256 collateralNeeded = _calculateCollateralNeeded(analysis, protection);
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
        
        uint256 repaymentNeeded = _calculateRepaymentNeeded(analysis, protection);
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
            
            // Choose repayment strategy based on risk type and debt composition
            if (analysis.riskType == LiquidationRisk.LEVERAGE_LIQUIDATION && analysis.hasLiquidityDebt) {
                IAmmalgamPair(pair).repayLiquidity(user);
            } else {
                IAmmalgamPair(pair).repay(user);
            }
        }
        
        return actualAmount;
    }

    function _calculateCollateralNeeded(
        RiskAnalysis memory analysis,
        UserProtection memory protection
    ) internal pure returns (uint256) {
        if (analysis.currentHealthFactor >= protection.targetHealthFactor) {
            return 0;
        }
        
        // Simplified calculation based on health factor deficit
        uint256 healthFactorDeficit = protection.targetHealthFactor - analysis.currentHealthFactor;
        return (healthFactorDeficit * protection.maxProtectionAmount) / HEALTH_FACTOR_SCALE;
    }

    function _calculateRepaymentNeeded(
        RiskAnalysis memory analysis,
        UserProtection memory protection
    ) internal pure returns (uint256) {
        if (analysis.currentHealthFactor >= protection.targetHealthFactor) {
            return 0;
        }
        
        // Simplified calculation based on health factor deficit
        uint256 healthFactorDeficit = protection.targetHealthFactor - analysis.currentHealthFactor;
        return (healthFactorDeficit * protection.maxProtectionAmount) / HEALTH_FACTOR_SCALE;
    }

    function _estimateNewHealthFactor(
        uint256 currentHealthFactor,
        uint256 protectionAmount,
        bool isCollateralAddition
    ) internal pure returns (uint256) {
        // Simplified estimation - in production would be more sophisticated
        uint256 improvement = (protectionAmount * HEALTH_FACTOR_SCALE) / 1000; // Rough estimate
        return isCollateralAddition ? 
            currentHealthFactor + improvement : 
            currentHealthFactor + improvement;
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
}
