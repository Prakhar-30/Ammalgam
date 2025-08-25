# Ammalgam Unified Liquidation Protection System

## Overview

The **Ammalgam Unified Liquidation Protection System** provides automated liquidation protection for Ammalgam protocol users through a reactive smart contract architecture. The system uses **enhanced Ammalgam-specific risk calculations** and automatically monitors positions across chains, executing protection strategies when multiple risk factors indicate liquidation danger.

**Protects Against All Three Ammalgam Liquidation Types:**
- **HARD (0)**: LTV-based liquidation (precise Ammalgam LTV + solvency validation)
- **SOFT (1)**: Saturation-based liquidation (time + position aging + utilization factors)  
- **LEVERAGE (2)**: Over-leveraged positions (high debt/collateral ratios + liquidity debt prioritization)

## Key Features

- **Enhanced Risk Detection**: Uses Ammalgam's actual LTV calculations and solvency validation
- **Cross-Chain Architecture**: Lasna RSC listens to Sepolia events, sends callbacks to Sepolia
- **Real-time Response**: Reacts to liquidations and position changes instantly with priority system
- **Smart Subscription Check**: Only processes subscribed users (gas efficient)
- **Multi-Factor Protection**: Combines health factor, Ammalgam LTV, solvency checks, and liquidation premiums
- **Intelligent Repayment**: Chooses optimal repayment strategy based on risk type and debt composition
- **Non-Custodial**: Users maintain control via token approvals

## Enhanced Architecture

**Reactive Contract (Lasna Testnet)**: 
- Monitors CRON events (5-minute intervals)
- Listens to Ammalgam events on Sepolia (liquidations, borrows, withdraws, repays, deposits)
- Extracts user data from events and sends cross-chain callbacks to Sepolia
- Smart event prioritization and subscription filtering

**Callback Contract (Sepolia Testnet)**:
- Manages user subscriptions and protection execution
- Performs enhanced risk analysis using Ammalgam's precise calculations
- Executes protection strategies with risk-adjusted amounts
- Integrates directly with Ammalgam pairs for protection execution

## Deployment

### Environment Variables

```bash
# Sepolia (where Ammalgam is deployed)
export SEPOLIA_RPC=<sepolia_rpc_url>
export SEPOLIA_PRIVATE_KEY=<your_private_key>

# Lasna Network (Reactive Smart Contracts)
export LASNA_RPC=<lasna_network_rpc>
export LASNA_PRIVATE_KEY=<reactive_private_key>

# Reactive Network contracts (Lasna)
export SEPOLIA_CALLBACK_PROXY_ADDR=<callback_proxy_address>
export SYSTEM_CONTRACT_ADDR=<system_contract_address>
export CRON_TOPIC=0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70

# Ammalgam contracts (Sepolia)
export WETH_USDC_PAIR=<weth_usdc_pair_address>
export WBTC_DAI_PAIR=<wbtc_dai_pair_address>

# Tokens (Sepolia)
export WETH=<weth_token_address>
export USDC=<usdc_token_address>
export WBTC=<wbtc_token_address>
export DAI=<dai_token_address>
```

### Deploy Contracts

**1. Deploy Callback Contract (Sepolia)**
```bash
forge create --broadcast --rpc-url $SEPOLIA_RPC --private-key $SEPOLIA_PRIVATE_KEY src/demos/ammalgam-protection/AmmalgamProtectionCallback.sol:AmmalgamProtectionCallback --value 0.01ether --constructor-args $SEPOLIA_CALLBACK_PROXY_ADDR
```

**2. Deploy Reactive Contract (Lasna)**
```bash
forge create --legacy --broadcast --rpc-url $LASNA_RPC --private-key $LASNA_PRIVATE_KEY src/demos/ammalgam-protection/AmmalgamProtectionReactive.sol:AmmalgamProtectionReactive --value 0.01ether --constructor-args $CALLBACK_ADDR $SYSTEM_CONTRACT_ADDR $CRON_TOPIC
```

**3. Configure Monitored Pairs (Lasna → Monitor Sepolia)**
```bash
cast send $REACTIVE_ADDR "addMonitoredPair(address)" --rpc-url $LASNA_RPC --private-key $LASNA_PRIVATE_KEY $WETH_USDC_PAIR
cast send $REACTIVE_ADDR "addMonitoredPair(address)" --rpc-url $LASNA_RPC --private-key $LASNA_PRIVATE_KEY $WBTC_DAI_PAIR
```

## Enhanced Protection Types

### Collateral Only (`COLLATERAL_ONLY = 0`)
- **Strategy**: Automatically deposits additional collateral when at risk
- **Risk-Adjusted Amounts**: Base + LTV excess + risk multipliers + emergency scaling
- **Best For**: Users with sufficient collateral tokens who want to maintain leverage
- **Triggers**: All liquidation risk types with multi-factor analysis

### Debt Repayment Only (`DEBT_REPAYMENT_ONLY = 1`) 
- **Strategy**: Automatically repays debt to improve health factor
- **Smart Repayment**: Chooses `repayLiquidity()` vs `repay()` based on risk type and debt composition
- **Best For**: Users who want to reduce position size when at risk  
- **Enhanced Triggers**: 
  - **Leverage + Liquidity Debt**: `repayLiquidity()` for deleveraging
  - **Soft + Liquidity Debt**: `repayLiquidity()` for saturation reduction  
  - **Hard or Standard Debt**: `repay()` for LTV improvement

## Enhanced Liquidation Risk Detection

### Hard Liquidation (LTV-based)
- **Enhanced Detection**: 
  - `ammalgamLTV = (netDebt * BIPS) / netCollateral` using Ammalgam's precise calculations
  - Direct solvency validation using Ammalgam's `validateSolvency()` logic
  - Hard liquidation premium assessment
- **Trigger Thresholds**: 
  - Ammalgam LTV ≥ 60% (START_NEGATIVE_PREMIUM_LTV_BIPS)
  - Health factor < user threshold
  - `wouldFailSolvency = true`
  - Hard liquidation premium > 0
- **Protection**: Immediate collateral deposit or debt repayment with emergency scaling

### Soft Liquidation (Saturation/Time-based)
- **Enhanced Detection**: 
  - `positionAge = block.timestamp - positionCreationTime`
  - `leverageRatio = (totalDebt * 1e18) / totalCollateral`
  - `borrowUtilization = (totalDebt * 1e18) / (totalCollateral + totalDebt)`
  - Soft liquidation premium based on position aging
- **Trigger Conditions**: 
  - Position age > 7 days AND leverage > 3x AND utilization > 80% AND soft premium > 5%
- **Protection**: Position adjustment to reduce saturation impact, prioritizes `repayLiquidity()` if applicable

### Leverage Liquidation (Over-leverage)
- **Enhanced Detection**: 
  - `leverageRatio ≥ 5x` OR `ammalgamLTV ≥ 75%` (START_PREMIUM_LTV_BIPS)
  - Detection of liquidity debt composition
  - Immediate action flags for critical leverage
- **Trigger Conditions**: 
  - Leverage ratio ≥ 5x OR Ammalgam LTV ≥ 75%
  - `requiresImmediateAction = true`
- **Protection**: Prioritizes `repayLiquidity()` for deleveraging, enhanced protection amounts (+80%)

## Enhanced Usage

### 1. Create Ammalgam Position (Sepolia)

**Supply Liquidity**
```bash
# Transfer tokens to Ammalgam pair on Sepolia
cast send $WETH "transfer(address,uint256)" --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR <AMOUNT>
cast send $USDC "transfer(address,uint256)" --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR <AMOUNT>

# Mint liquidity position
cast send $WETH_USDC_PAIR "mint(address)" --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS
```

**Borrow Against Position**
```bash
cast send $WETH_USDC_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS <X_AMOUNT> <Y_AMOUNT> 0x
```

### 2. Subscribe to Enhanced Protection (Sepolia)

**Approve Protection Asset**
```bash
# For collateral protection
cast send $WETH 'approve(address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>

# For debt repayment protection  
cast send $USDC 'approve(address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>
```

**Subscribe with Enhanced Parameters**
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY <PAIR_ADDRESS> <PROTECTION_TYPE> <THRESHOLD> <TARGET> <PROTECTION_ASSET> <MAX_AMOUNT>
```

**Enhanced Parameters:**
- `PAIR_ADDRESS`: Ammalgam pair contract address on Sepolia
- `PROTECTION_TYPE`: 0 (Collateral Only) or 1 (Debt Repayment Only)
- `THRESHOLD`: Health factor threshold (e.g., `1200000000000000000` for 1.2)
- `TARGET`: Target health factor after protection (e.g., `1500000000000000000` for 1.5)
- `PROTECTION_ASSET`: Token address for protection on Sepolia
- `MAX_AMOUNT`: Maximum tokens to use per protection action

### 3. Enhanced Monitoring & Analytics (Sepolia)

**Detailed Position Analysis**
```bash
# Get comprehensive risk analysis using Ammalgam calculations
cast call $CALLBACK_ADDR "analyzeUserPosition(address,address)" --rpc-url $SEPOLIA_RPC <USER_ADDRESS> <PAIR_ADDRESS>
# Returns: healthFactor, ammalgamLTV, riskType, wouldFailSolvency, hardLiquidationPremium, softLiquidationPremium
```

**Risk Assessment with Reasons**
```bash
# Get detailed risk assessment with explanation
cast call $CALLBACK_ADDR "isPositionAtRisk(address,address)" --rpc-url $SEPOLIA_RPC <USER_ADDRESS> <PAIR_ADDRESS>
# Returns: atRisk (bool), riskType (enum), reason (string)
```

**System-Wide Statistics**
```bash
# Get protection system statistics
cast call $CALLBACK_ADDR "getSystemStats()" --rpc-url $SEPOLIA_RPC
# Returns: totalActiveUsers, totalActiveProtections, averageHealthFactor, usersAtRisk

# Cross-chain system status
cast call $REACTIVE_ADDR "getSystemStatus()" --rpc-url $LASNA_RPC
# Returns: isProcessing, monitoredPairsCount, lastEmergency, lastPeriodic
```

**Network Information**
```bash
# Verify cross-chain setup
cast call $REACTIVE_ADDR "getNetworkInfo()" --rpc-url $LASNA_RPC
# Returns network configuration and chain IDs
```

### 4. Unsubscribe (Sepolia)

```bash
cast send $CALLBACK_ADDR "unsubscribeFromProtection(address)" --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY <PAIR_ADDRESS>
```

## Enhanced Examples

### Example 1: Enhanced Collateral Protection for WETH/USDC

```bash
# 1. Approve WETH for protection (Sepolia)
cast send $WETH 'approve(address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR 5000000000000000000

# 2. Subscribe with enhanced parameters
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR 0 1200000000000000000 1500000000000000000 $WETH 1000000000000000000

# 3. Monitor with enhanced analytics
cast call $CALLBACK_ADDR "analyzeUserPosition(address,address)" --rpc-url $SEPOLIA_RPC $USER_ADDRESS $WETH_USDC_PAIR
```

### Example 2: Enhanced Debt Repayment Protection for WBTC/DAI

```bash
# 1. Approve DAI for debt repayment (Sepolia)
cast send $DAI 'approve(address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR 2000000000000000000000

# 2. Subscribe with lower threshold for aggressive protection
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $SEPOLIA_RPC --private-key $USER_PRIVATE_KEY $WBTC_DAI_PAIR 1 1100000000000000000 1300000000000000000 $DAI 500000000000000000000

# 3. Check if position is at risk
cast call $CALLBACK_ADDR "isPositionAtRisk(address,address)" --rpc-url $SEPOLIA_RPC $USER_ADDRESS $WBTC_DAI_PAIR
```

## Enhanced System Operation

### Cross-Chain Monitoring Architecture

**Lasna Testnet (RSC)**:
- Monitors Sepolia Ammalgam events in real-time
- Processes and extracts user data from events
- Sends callbacks to Sepolia with proper function signatures
- Manages timing and priority-based response

**Sepolia Testnet (Execution)**:
- Receives callbacks from Lasna RSC
- Performs enhanced Ammalgam-specific risk analysis
- Executes protection strategies directly with Ammalgam pairs
- Manages user subscriptions and protection state

### Enhanced Automatic Monitoring

**Periodic Checks (Every 5 Minutes)**
- **Trigger**: CRON event on Lasna → callback to Sepolia
- **Process**: System checks ALL subscribed users across ALL monitored pairs
- **Analysis**: Enhanced risk analysis using Ammalgam's precise LTV calculations
- **Execution**: Risk-adjusted protection amounts with emergency scaling

**Real-time Cross-Chain Event Response**
- **Liquidation Events**: Emergency protection with 1-minute cooldown (immediate response)
- **Borrow/Withdraw Events**: High-priority checks with 30-second cooldown (risk increasing)
- **Repay/Deposit Events**: Lower-priority checks with 60-second cooldown (risk decreasing)

**Enhanced Subscription Filtering**
- Only processes users who are subscribed to protection for specific pairs
- Skips non-subscribers automatically (gas efficient cross-chain operations)
- No wasted computation on unprotected positions

### Enhanced Event Priority System

1. **🚨 CRITICAL**: Liquidation events from Sepolia (immediate cross-chain response)
2. **⚡ HIGH PRIORITY**: Borrow/Withdraw events from Sepolia (30-second cooldown)
3. **📉 LOWER PRIORITY**: Repay/Deposit events from Sepolia (60-second cooldown)

## Enhanced Protection Calculations

### Multi-Factor Risk Assessment
```
Protection Needed = (
    wouldFailSolvency OR
    ammalgamLTV ≥ 60% OR  
    healthFactor < userThreshold OR
    hardLiquidationPremium > 0 OR
    (softRisk AND softPremium > 5%) OR
    (leverageRisk AND requiresImmediateAction)
)
```

### Risk-Adjusted Protection Amounts
```
baseAmount = max(
    (healthFactorDeficit * maxProtectionAmount) / 1e18,
    ((ammalgamLTV - 60%) * maxProtectionAmount) / 10000
)

riskAdjustedAmount = baseAmount * riskMultiplier:
• Leverage Risk: +50% (deleveraging focus)
• Soft Risk: +25% (saturation reduction)
• Emergency Situations: +100-150% (critical response)
```

### Enhanced Health Factor Calculation
```
Enhanced Health Factor = (netCollateral * 1e18) / netDebt

Where netCollateral and netDebt use Ammalgam's precise calculations:
• Price range considerations (sqrtPriceMin/Max)
• Active liquidity scaling
• Slippage adjustments for conservative estimates
• Asset-specific risk factors
```

### Smart Repayment Strategy
```
if (leverageRisk AND hasLiquidityDebt):
    → repayLiquidity() // Deleveraging strategy
elif (softRisk AND hasLiquidityDebt):  
    → repayLiquidity() // Saturation reduction
else:
    → repay() // Standard LTV improvement
```

