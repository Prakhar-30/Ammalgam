# Ammalgam Unified Liquidation Protection System

## Overview

The **Ammalgam Unified Liquidation Protection System** is a comprehensive reactive smart contract system that provides automated liquidation protection for Ammalgam protocol users. The system monitors positions across multiple Ammalgam pairs and automatically executes protection strategies when health factors drop below defined thresholds.

**Key Improvement**: The system intelligently skips non-subscribers to save gas and avoid unnecessary processing when liquidation or position change events occur for users who haven't opted into protection services.

The system protects against all three types of Ammalgam liquidations:
- **HARD (0)**: LTV-based liquidation with premium calculations
- **SOFT (1)**: Saturation-based liquidation due to time passage  
- **LEVERAGE (2)**: Leverage-based liquidation for over-leveraged positions

## Key Features

- **Complete Liquidation Coverage**: Protects against Hard, Soft, and Leverage liquidations
- **Smart Subscriber Filtering**: Automatically skips non-subscribers to save gas
- **Real-time Monitoring**: Reactive to position changes, liquidation events, and CRON triggers
- **Multi-Pair Support**: Monitor positions across unlimited Ammalgam pairs
- **Two Protection Strategies**: Collateral deposit or debt repayment (simplified approach)
- **Emergency Response**: Immediate protection triggers on liquidation events
- **Gas Optimized**: Intelligent filtering and efficient batch processing
- **Non-Custodial**: Users maintain control through approval mechanisms
- **Comprehensive Analytics**: Advanced risk scoring and subscription tracking
- **Production Ready**: Full error handling, statistics, and monitoring capabilities

## Architecture

**Reactive Contract (Kopli Network)**: 
- Runs on Reactive Network (Kopli)
- Subscribes to CRON events for periodic monitoring (every 5 minutes)
- Monitors liquidation events for emergency response
- Tracks position changes (borrow, withdraw, repay, deposit)
- Extracts specific user addresses from events for targeted checks

**Callback Contract (Destination Chain)**:
- Runs on the same chain as Ammalgam (e.g., Ethereum, Sepolia)
- **Validates user subscriptions before executing protection**
- Advanced risk analysis for all three liquidation types
- Executes protection strategies only for subscribed users
- Tracks statistics including skipped non-subscribers

## Subscriber Validation Logic

### Emergency Response Flow:
1. **Liquidation Event Detected**: Extract borrower address from event
2. **Subscription Check**: Verify if borrower has active protection for this pair
3. **Action Decision**:
   - ✅ **Subscribed**: Execute emergency protection check
   - ❌ **Not Subscribed**: Skip and emit `NonSubscriberSkipped` event

### Position Change Flow:
1. **Position Event Detected**: Extract user address from event (borrow/withdraw/repay/deposit)
2. **Subscription Check**: Verify if user has active protection for this pair
3. **Action Decision**:
   - ✅ **Subscribed**: Execute position risk analysis
   - ❌ **Not Subscribed**: Skip and increment `skippedNonSubscribers` counter

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
export AMMALGAM_FACTORY=<ammalgam_factory_address>
export WETH_USDC_PAIR=<weth_usdc_pair_address>
export WBTC_DAI_PAIR=<wbtc_dai_pair_address>

# Test tokens
export WETH=<weth_token_address>
export USDC=<usdc_token_address>
export WBTC=<wbtc_token_address>
export DAI=<dai_token_address>
```

### Deploy Contracts

**1. Deploy Callback Contract (Destination Chain)**
```bash
forge create --broadcast --rpc-url $DESTINATION_RPC --private-key $DESTINATION_PRIVATE_KEY src/demos/ammalgam-protection/AmmalgamProtectionCallback.sol:AmmalgamProtectionCallback --value 0.01ether --constructor-args $DESTINATION_CALLBACK_PROXY_ADDR
```

**2. Deploy Reactive Contract (Kopli)**
```bash
forge create --legacy --broadcast --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY src/demos/ammalgam-protection/AmmalgamProtectionReactive.sol:AmmalgamProtectionReactive --value 0.01ether --constructor-args $CALLBACK_ADDR $SYSTEM_CONTRACT_ADDR $CRON_TOPIC
```

**3. Configure Monitored Pairs**
```bash
# Add WETH/USDC pair
cast send $REACTIVE_ADDR "addMonitoredPair(address)" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $WETH_USDC_PAIR

# Add WBTC/DAI pair
cast send $REACTIVE_ADDR "addMonitoredPair(address)" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $WBTC_DAI_PAIR

# Add multiple pairs at once
cast send $REACTIVE_ADDR "addMultiplePairs(address[])" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY "[$WETH_USDC_PAIR,$WBTC_DAI_PAIR]"
```

## Protection Types

### 1. Collateral Only (`COLLATERAL_ONLY = 0`)
Automatically deposits additional collateral when health factor drops below threshold.

**Best for**: Users with sufficient collateral tokens who want to maintain their leverage
**Triggers**: All liquidation risk types (Hard, Soft, Leverage)

### 2. Debt Repayment Only (`DEBT_REPAYMENT_ONLY = 1`) 
Automatically repays debt to improve health factor and reduce leverage.

**Best for**: Users who want to reduce their position size when at risk
**Triggers**: All liquidation risk types with intelligent repayment strategy selection

## Liquidation Risk Types

### Hard Liquidation Protection
- **Risk Type**: LTV-based liquidation when debt/collateral ratio exceeds limits
- **Detection**: `currentHealthFactor = (totalCollateral * 1e18) / totalDebt`
- **Threshold**: When health factor drops below user-defined threshold (e.g., 1.2)
- **Protection**: Immediate collateral deposit or debt repayment

### Soft Liquidation Protection
- **Risk Type**: Saturation-based liquidation due to time passage and position aging
- **Detection**: `positionAge > 7 days && leverageRatio > 2x && borrowUtilization > 80%`
- **Threshold**: Time-based risk accumulation
- **Protection**: Position adjustment to reduce saturation impact

### Leverage Liquidation Protection
- **Risk Type**: Over-leveraged positions that become unsustainable
- **Detection**: `leverageRatio = (totalDebt * 1e18) / totalCollateral > 5x`
- **Threshold**: High leverage ratios (>5x dangerous, >3x monitored)
- **Protection**: Prioritizes liquidity debt repayment for effective deleveraging

## Usage

### 1. Create Ammalgam Position

**Supply Liquidity to Pair**
```bash
# Transfer tokens to pair and mint liquidity
cast send $WETH "transfer(address,uint256)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR <AMOUNT>
cast send $USDC "transfer(address,uint256)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR <AMOUNT>
cast send $WETH_USDC_PAIR "mint(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS
```

**Borrow Against Position**
```bash
cast send $WETH_USDC_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS <X_AMOUNT> <Y_AMOUNT> 0x
```

### 2. Subscribe to Protection

**Approve Protection Asset**
```bash
# For collateral protection - approve collateral token
cast send $WETH 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>

# For debt repayment protection - approve debt token
cast send $USDC 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR <AMOUNT>
```

**Subscribe to Protection**
```bash
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY <PAIR_ADDRESS> <PROTECTION_TYPE> <THRESHOLD> <TARGET> <PROTECTION_ASSET> <MAX_AMOUNT>
```

**Parameters:**
- `PAIR_ADDRESS`: Ammalgam pair contract address
- `PROTECTION_TYPE`: 0 (Collateral Only) or 1 (Debt Repayment Only)
- `THRESHOLD`: Health factor threshold (e.g., `1200000000000000000` for 1.2)
- `TARGET`: Target health factor after protection (e.g., `1500000000000000000` for 1.5)
- `PROTECTION_ASSET`: Token address for protection (WETH for collateral, USDC for debt repayment)
- `MAX_AMOUNT`: Maximum tokens to use per protection action

### 3. Monitor Protection

**Check Subscription Status**
```bash
cast call $CALLBACK_ADDR "isUserSubscribed(address,address)" --rpc-url $DESTINATION_RPC <USER_ADDRESS> <PAIR_ADDRESS>
```

**Check Protection Configuration**
```bash
cast call $CALLBACK_ADDR "getUserProtection(address,address)" --rpc-url $DESTINATION_RPC <USER_ADDRESS> <PAIR_ADDRESS>
```

**Get Protection Statistics**
```bash
cast call $CALLBACK_ADDR "getUserStats(address,address)" --rpc-url $DESTINATION_RPC <USER_ADDRESS> <PAIR_ADDRESS>
```

**System-wide Statistics (Including Skipped Non-Subscribers)**
```bash
cast call $CALLBACK_ADDR "getSystemHealth()" --rpc-url $DESTINATION_RPC
```

**Reactive Contract Status**
```bash
cast call $REACTIVE_ADDR "getSystemStatus()" --rpc-url $REACTIVE_RPC
cast call $REACTIVE_ADDR "getStats()" --rpc-url $REACTIVE_RPC
```

### 4. Unsubscribe

```bash
cast send $CALLBACK_ADDR "unsubscribeFromProtection(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY <PAIR_ADDRESS>
```

## Examples

### Example 1: Collateral Protection for WETH/USDC Position

```bash
# 1. Create position (assuming you have WETH and USDC)
cast send $WETH_USDC_PAIR "mint(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS
cast send $WETH_USDC_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS 1000000000000000000 1500000000 0x

# 2. Approve WETH for collateral protection
cast send $WETH 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR 5000000000000000000

# 3. Subscribe to collateral protection
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WETH_USDC_PAIR 0 1200000000000000000 1500000000000000000 $WETH 1000000000000000000
```

### Example 2: Debt Repayment Protection for WBTC/DAI Position

```bash
# 1. Create leveraged position
cast send $WBTC_DAI_PAIR "mint(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS
cast send $WBTC_DAI_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS 50000000 1000000000000000000000 0x

# 2. Approve DAI for debt repayment
cast send $DAI 'approve(address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $CALLBACK_ADDR 2000000000000000000000

# 3. Subscribe to debt repayment protection
cast send $CALLBACK_ADDR 'subscribeToProtection(address,uint8,uint256,uint256,address,uint256)' --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $WBTC_DAI_PAIR 1 1100000000000000000 1300000000000000000 $DAI 500000000000000000000
```

### Example 3: Monitor System Activity (Including Non-Subscriber Statistics)

```bash
# Check how many users are protected
cast call $CALLBACK_ADDR "getActiveUsersCount()" --rpc-url $DESTINATION_RPC

# Get system-wide statistics including skipped non-subscribers
cast call $CALLBACK_ADDR "getSystemHealth()" --rpc-url $DESTINATION_RPC

# Check if specific user is subscribed
cast call $CALLBACK_ADDR "isUserSubscribed(address,address)" --rpc-url $DESTINATION_RPC $USER_ADDRESS $PAIR_ADDRESS

# Check reactive contract status
cast call $REACTIVE_ADDR "getSystemStatus()" --rpc-url $REACTIVE_RPC

# Get all monitored pairs
cast call $REACTIVE_ADDR "getMonitoredPairs()" --rpc-url $REACTIVE_RPC
```

## Event Monitoring

The system monitors and responds to several key events:

### Callback Contract Events
- `UserSubscribed`: User successfully subscribed to protection
- `ProtectionExecuted`: Protection successfully executed with details
- `ProtectionFailed`: Protection attempt failed with reason
- `EmergencyProtectionExecuted`: Emergency protection triggered
- `NonSubscriberSkipped`: **NEW** - Non-subscriber was skipped to save gas
- `ProtectionCycleCompleted`: Monitoring cycle completed with statistics

### Reactive Contract Events
- `ProtectionCheckTriggered`: Protection check initiated with trigger type
- `ProtectionCompleted`: Protection cycle completed
- `EmergencyTriggered`: Emergency response activated
- `PairAdded/PairRemoved`: Monitored pairs management

### Ammalgam Protocol Events (Monitored)
- `Liquidate`: Liquidation occurred (triggers emergency response)
- `Borrow/Withdraw`: Risk-increasing events (high priority)
- `Repay/Deposit`: Risk-decreasing events (lower priority)

## Gas Optimization Features

### Smart Subscriber Filtering
The system now includes intelligent filtering to avoid wasting gas on non-subscribers:

1. **Liquidation Events**: When a liquidation is detected, the system first checks if the borrower has an active subscription before executing any protection logic.

2. **Position Change Events**: When users borrow, withdraw, repay, or deposit, the system verifies subscription status before analyzing position risk.

3. **Statistics Tracking**: The system tracks how many non-subscribers were skipped, providing visibility into gas savings.

### Gas Savings Benefits
- **Reduced Callback Gas**: Skip expensive position analysis for non-subscribers
- **Lower Network Congestion**: Fewer unnecessary transactions
- **Cost Efficiency**: Protection costs only borne by actual subscribers
- **Scalability**: System can monitor large numbers of pairs without excessive gas usage

## Testing and Development

### Create Test Position with Specific Health Factor

**1. Calculate Target Amounts**
```javascript
// Example: Create position with 1.5 health factor
const collateralValue = 10000; // $10,000 in collateral
const targetHealthFactor = 1.5;
const maxDebtValue = collateralValue / targetHealthFactor; // $6,666 max debt
```

**2. Execute Position Creation**
```bash
# Supply collateral
cast send $WETH_USDC_PAIR "mint(address)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS

# Borrow to achieve target health factor
cast send $WETH_USDC_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $DESTINATION_RPC --private-key $USER_PRIVATE_KEY $USER_ADDRESS <CALCULATED_X> <CALCULATED_Y> 0x
```

**3. Monitor Health Factor**
```bash
cast call $WETH_USDC_PAIR "getInputParams(address,bool)" --rpc-url $DESTINATION_RPC $USER_ADDRESS true
```

### Testing Non-Subscriber Filtering

**1. Create Position Without Subscribing**
```bash
# Create position but don't subscribe to protection
cast send $WETH_USDC_PAIR "borrow(address,uint256,uint256,bytes)" --rpc-url $DESTINATION_RPC --private-key $NON_SUBSCRIBER_KEY $NON_SUBSCRIBER_ADDR <X_AMOUNT> <Y_AMOUNT> 0x
```

**2. Trigger Events and Monitor Skipping**
```bash
# The system should skip this user and emit NonSubscriberSkipped events
# Check statistics to see skipped count
cast call $CALLBACK_ADDR "getSystemHealth()" --rpc-url $DESTINATION_RPC
```

### Manual Testing Functions

**Force Protection Check**
```bash
cast send $REACTIVE_ADDR "forceProtectionCheck()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

**Force Emergency Check for Specific Pair**
```bash
cast send $REACTIVE_ADDR "forceEmergencyCheck(address)" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $PAIR_ADDRESS
```

**Force Check for Specific User**
```bash
cast send $REACTIVE_ADDR "forceUserCheck(address,address)" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY $USER_ADDRESS $PAIR_ADDRESS
```

### Debug Functions

**Check Processing Status**
```bash
cast call $REACTIVE_ADDR "isProcessingActive()" --rpc-url $REACTIVE_RPC
```

**Reset if Stuck**
```bash
cast send $REACTIVE_ADDR "resetProcessingFlag()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
cast send $REACTIVE_ADDR "resetTimestamps()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

**Emergency Pause**
```bash
cast send $REACTIVE_ADDR "emergencyPause()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
cast send $REACTIVE_ADDR "emergencyUnpause()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

## Advanced Configuration

### Health Factor Calculation

The system uses a simplified but effective health factor calculation:

```
Health Factor = (Total Collateral Value * 1e18) / Total Debt Value

Where:
- Total Collateral = DEPOSIT_L + DEPOSIT_X + DEPOSIT_Y  
- Total Debt = BORROW_L + BORROW_X + BORROW_Y
- Values are in the same units (typically in L assets)
```

### Risk Type Determination Logic

```
1. LEVERAGE Risk: leverageRatio >= 5x
2. SOFT Risk: positionAge > 7 days AND leverageRatio > 3x AND borrowUtilization > 80%
3. HARD Risk: All other cases (standard LTV-based risk)
```

### Subscription Validation

```solidity
function _isUserSubscribedToPair(address user, address pair) internal view returns (bool) {
    return userProtections[user][pair].isActive;
}
```

### Protection Amount Calculation

**Collateral Needed:**
```
additionalCollateral = (targetHF * totalDebt) - currentCollateral
actualAmount = min(additionalCollateral, maxProtectionAmount)
```

**Debt Repayment Needed:**
```
debtToRepay = totalDebt - (currentCollateral / targetHF)
actualAmount = min(debtToRepay, maxProtectionAmount)
```

### Event Topic Calculation

For production deployment, calculate actual event topics:

```bash
# Liquidation event
cast keccak "Liquidate(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"

# Position change events
cast keccak "Borrow(address,uint256,uint256)"
cast keccak "Withdraw(address,uint256)"
cast keccak "Repay(address,uint256,uint256)"
cast keccak "Deposit(address,uint256)"
```

## Troubleshooting

### Common Issues

**Protection Not Triggering:**
- Verify user is subscribed: `isUserSubscribed(user, pair)`
- Check health factor is actually below threshold
- Ensure token approvals are sufficient
- Verify pair is added to monitored pairs

**Non-Subscriber Events:**
- Check `NonSubscriberSkipped` events to see if users are being filtered
- Monitor `skippedNonSubscribers` counter in system statistics
- Ensure intended users have actually subscribed to protection

**Insufficient Funds Error:**
- Increase token balance for protection asset
- Increase approval amount
- Check maxProtectionAmount is reasonable

**Position Not Found:**
- Verify correct pair address in subscription
- Ensure user actually has borrowing position
- Check pair is deployed and active

**Processing Stuck:**
```bash
# Reset processing flag
cast send $REACTIVE_ADDR "resetProcessingFlag()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY

# Reset timestamps
cast send $REACTIVE_ADDR "resetTimestamps()" --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY
```

**Events Not Triggering:**
- Verify event topic hashes are correct
- Check pair is properly added to monitored pairs
- Ensure reactive contract has sufficient ETH for callbacks

### Gas Issues

**High Gas Usage:**
- Monitor `skippedNonSubscribers` to see gas savings from filtering
- Reduce number of monitored pairs if needed
- Increase emergency cooldown periods

**Out of Gas:**
- Increase callback gas limit in reactive contract
- Verify subscription filtering is working properly
- Reduce frequency of checks

### Security Considerations

**User Asset Safety:**
- System is non-custodial - users control assets via approvals
- Users can revoke approvals at any time
- Protection amounts are limited by user-defined maximums
- Only subscribed users receive protection services

**Smart Contract Risks:**
- Contracts are not upgradeable by design
- Emergency pause functionality for reactive contract
- Comprehensive error handling and validation
- Subscription validation prevents unauthorized protection

**Privacy and Filtering:**
- System respects user choice by only protecting subscribers
- Non-subscribers are handled gracefully without wasting resources
- Subscription status is publicly verifiable

## System Requirements

- **Minimum Token Balance**: Users need sufficient balance of protection assets
- **Token Approvals**: Must approve callback contract for protection tokens
- **Active Subscription**: Must subscribe to protection for specific pairs
- **Health Factor**: Position must have borrowing debt to require protection
- **Pair Support**: Ammalgam pair must be added to monitored pairs list
- **Network Requirements**: Reactive Network (Kopli) and destination chain connectivity

## Production Deployment Checklist

- [ ] Deploy callback contract with correct constructor parameters
- [ ] Deploy reactive contract with correct addresses and CRON topic
- [ ] Add all relevant Ammalgam pairs to monitoring
- [ ] Calculate and update correct event topic hashes
- [ ] Test subscription validation works correctly
- [ ] Verify non-subscriber filtering saves gas as expected
- [ ] Test with small positions and amounts first
- [ ] Set up monitoring for `NonSubscriberSkipped` events
- [ ] Verify gas limits are sufficient for your use case
- [ ] Document emergency procedures and admin functions
- [ ] Set up alerting for protection statistics and success rates
- [ ] Consider implementing additional analytics for gas savings

## Support and Maintenance

For ongoing support:
1. Monitor system statistics including skipped non-subscribers
2. Track gas savings from subscription filtering
3. Update monitored pairs as new Ammalgam pairs are deployed
4. Adjust gas limits based on network conditions
5. Monitor for new Ammalgam protocol updates that might affect protection logic
6. Regular testing of subscription validation and filtering logic
7. Review protection success rates and optimize thresholds as needed

## Conclusion

The Ammalgam Unified Liquidation Protection System provides comprehensive, automated protection against all three types of Ammalgam liquidations while intelligently optimizing gas usage through subscriber filtering. With its reactive architecture, intelligent risk detection, and non-custodial design, it offers users peace of mind while maintaining capital efficiency.

The system is production-ready with extensive testing capabilities, comprehensive monitoring, robust error handling, and smart gas optimization features. Users can protect their positions with minimal setup while maintaining full control over their assets, and the system ensures efficient operation by only processing protection logic for actual subscribers.
