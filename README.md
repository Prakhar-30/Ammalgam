# Ammalgam Unified Liquidation Protection System

## Overview

The **Ammalgam Unified Liquidation Protection System** provides automated liquidation protection for Ammalgam protocol users through a reactive smart contract architecture. The system automatically monitors positions and executes protection strategies when health factors drop below user-defined thresholds.

**Protects Against All Three Ammalgam Liquidation Types:**
- **HARD (0)**: LTV-based liquidation (health factor protection)
- **SOFT (1)**: Saturation-based liquidation (time + position aging)  
- **LEVERAGE (2)**: Over-leveraged positions (high debt/collateral ratios)

## Key Features

- **Automatic Protection**: No manual intervention required
- **Real-time Response**: Reacts to liquidations and position changes instantly  
- **Smart Subscription Check**: Only processes subscribed users (gas efficient)
- **Multi-Pair Support**: Monitor unlimited Ammalgam pairs
- **Two Protection Types**: Collateral deposit OR debt repayment
- **Non-Custodial**: Users maintain control via token approvals

## Architecture

**Reactive Contract (Kopli Network)**: 
- Monitors CRON events (5-minute intervals)
- Detects liquidation events for emergency response
- Tracks position changes (borrow/withdraw/repay/deposit)
- Smart event prioritization and subscription filtering

**Callback Contract (Destination Chain)**:
- Manages user subscriptions and protection execution
- Analyzes liquidation risks (Hard/Soft/Leverage)
- Executes protection strategies automatically
- Handles subscription validation and user management

## Deployment

### Environment Variables

```bash
# Destination chain (where Ammalgam is deployed)
export DESTINATION_RPC=<your_destination_rpc_url>
export DESTINATION_PRIVATE_KEY=<your_private_key>

# Reactive Network
export REACTIVE_RPC=<reactive_network_rpc>
export REACTIVE_PRIVATE_KEY=<reactive_private_key>

# Reactive Network contracts
export DESTINATION_CALLBACK_PROXY_ADDR=<callback_proxy_address>
export SYSTEM_CONTRACT_ADDR=<system_contract_address>
export CRON_TOPIC=0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70

# Ammalgam contracts
export WETH_USDC_PAIR=<weth_usdc_pair_address>
export WBTC_DAI_PAIR=<wbtc_dai_pair_address>

# Tokens
export WETH=<weth_token_address>
export USDC=<usdc_token_address>
export WBTC=<wbtc_token_address>
export DAI=<dai_token_address>
```

### Deploy Contracts

**1. Deploy Callback Contract**
```bash
forge create --broadcast --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY src/demos/ammalgam-protection/AmmalgamProtectionCallback.sol:AmmalgamProtectionCallback --value 0.01ether --constructor-args $DESTINATION_CALLBACK_PROXY_ADDR
```

**2. Deploy Reactive Contract**
```bash
forge create --legacy --broadcast --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY src/demos/ammalgam-protection/AmmalgamProtectionReactive.sol:AmmalgamProtectionReactive --value 0.01ether --constructor-args $CALLBACK_ADDR $SYSTEM_CONTRACT_ADDR $CRON_TOPIC
```

**3. Configure Monitored Pairs**
```bash
cast send $REACTIVE_ADDR "addMonitoredPair(address)" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $WETH_USDC_PAIR
cast send $REACTIVE_ADDR "addMonitoredPair(address)" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $WBTC_DAI_PAIR
```

## Protection Types

### Collateral Only (`COLLATERAL_ONLY = 0`)
- **Strategy**: Automatically deposits additional collateral when at risk
- **Best For**: Users with sufficient collateral tokens who want to maintain leverage
- **Triggers**: All liquidation risk types

### Debt Repayment Only (`DEBT_REPAYMENT_ONLY = 1`) 
- **Strategy**: Automatically repays debt to improve health factor
- **Best For**: Users who want to reduce position size when at risk  
- **Triggers**: Intelligent repayment (standard debt vs liquidity debt based on risk type)

## Liquidation Risk Detection

### Hard Liquidation (LTV-based)
- **Detection**: `healthFactor = (totalCollateral * 1e18) / totalDebt`
- **Trigger**: Health factor drops below user threshold
- **Protection**: Immediate collateral deposit or debt repayment

### Soft Liquidation (Saturation/Time-based)
- **Detection**: `positionAge > 7 days && leverageRatio > 3x && borrowUtilization > 80%`
- **Trigger**: Time-based risk accumulation
- **Protection**: Position adjustment to reduce saturation impact

### Leverage Liquidation (Over-leverage)
- **Detection**: `leverageRatio = (totalDebt * 1e18) / totalCollateral > 5x`  
- **Trigger**: Excessive borrowing relative to collateral
- **Protection**: Prioritizes liquidity debt repayment for deleveraging

## Usage

### 1. Create Ammalgam Position

**Supply Liquidity**
```bash
# Transfer tokens to pair
cast send $WETH "transfer(address,uint256)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR <AMOUNT>
cast send $USDC "transfer(address,uint256)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR <AMOUNT>

# Mint liquidity position
cast send $WETH_USDC_PAIR "mint(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS
```

**Borrow Against Position**
```bash
cast send $WETH_USDC_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS <X_AMOUNT> <Y_AMOUNT> 0x
```

### 2. Subscribe to Protection

**Approve Protection Asset**
```bash
# For collateral protection
cast send $WETH 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>

# For debt repayment protection  
cast send $USDC 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>
```

**Subscribe**
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY <PAIR_ADDRESS> <PROTECTION_TYPE> <THRESHOLD> <TARGET> <PROTECTION_ASSET> <MAX_AMOUNT>
```

**Parameters:**
- `PAIR_ADDRESS`: Ammalgam pair contract address  
- `PROTECTION_TYPE`: 0 (Collateral Only) or 1 (Debt Repayment Only)
- `THRESHOLD`: Health factor threshold (e.g., `1200000000000000000` for 1.2)
- `TARGET`: Target health factor after protection (e.g., `1500000000000000000` for 1.5)
- `PROTECTION_ASSET`: Token address for protection
- `MAX_AMOUNT`: Maximum tokens to use per protection action

### 3. Monitor Protection

**Check Protection Status**
```bash
cast call $CALLBACK_ADDR "getUserProtection(address,address)" --rpc-url $DESTINATION_RPC <USER_ADDRESS> <PAIR_ADDRESS>
```

**Check if User is Subscribed**
```bash
cast call $CALLBACK_ADDR "isUserSubscribedToPair(address,address)" --rpc-url $DESTINATION_RPC <USER_ADDRESS> <PAIR_ADDRESS>
```

**System Status**
```bash
cast call $CALLBACK_ADDR "getActiveUsersCount()" --rpc-url $DESTINATION_RPC
cast call $REACTIVE_ADDR "getSystemStatus()" --rpc-url $REACTIVE_RPC
```

### 4. Unsubscribe

```bash
cast send $CALLBACK_ADDR "unsubscribeFromProtection(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY <PAIR_ADDRESS>
```

## Examples

### Example 1: Collateral Protection for WETH/USDC

```bash
# 1. Approve WETH for protection
cast send $WETH 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR 5000000000000000000

# 2. Subscribe with 1.2 threshold, 1.5 target, max 1 WETH per protection
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR 0 1200000000000000000 1500000000000000000 $WETH 1000000000000000000
```

### Example 2: Debt Repayment Protection for WBTC/DAI

```bash
# 1. Approve DAI for debt repayment
cast send $DAI 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR 2000000000000000000000

# 2. Subscribe with 1.1 threshold, 1.3 target, max 500 DAI per protection
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WBTC_DAI_PAIR 1 1100000000000000000 1300000000000000000 $DAI 500000000000000000000
```

## System Operation

### Automatic Monitoring

**Periodic Checks (Every 5 Minutes)**
- System checks ALL subscribed users across ALL monitored pairs
- Analyzes health factors and risk types
- Executes protection if thresholds are breached

**Real-time Event Response**
- **Liquidation Events**: Emergency protection for liquidated borrowers (if subscribed)
- **Borrow/Withdraw Events**: High-priority checks for users increasing risk
- **Repay/Deposit Events**: Lower-priority checks for users decreasing risk

**Smart Subscription Filtering**
- Only processes users who are subscribed to protection
- Skips non-subscribers automatically (gas efficient)
- No wasted computation on unprotected positions

### Event Priority System

1. **🚨 CRITICAL**: Liquidation events (immediate response)
2. **⚡ HIGH PRIORITY**: Borrow/Withdraw events (30-second cooldown)
3. **📉 LOWER PRIORITY**: Repay/Deposit events (60-second cooldown)

## Important Notes

### Health Factor Calculation
```
Health Factor = (Total Collateral * 1e18) / Total Debt

Where:
- Total Collateral = DEPOSIT_L + DEPOSIT_X + DEPOSIT_Y  
- Total Debt = BORROW_L + BORROW_X + BORROW_Y
```

### Protection Amount Calculation
The system uses simplified calculations based on health factor deficit:
```
amount = (healthFactorDeficit * maxProtectionAmount) / 1e18
actualAmount = min(calculatedAmount, maxProtectionAmount)
```

### Cooldown Periods
- **Regular Protection**: 5 minutes between protections
- **Emergency Protection**: 1 minute between protections  
- **Position Change**: 30-60 seconds based on risk level

