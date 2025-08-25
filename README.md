# RSC integration workflow overview
sequenceDiagram
    participant User
    participant ReactiveContract as Reactive Contract<br/>(Kopli Network)
    participant CallbackContract as Callback Contract<br/>(Destination Chain)
    participant AmmalgamPair as Ammalgam Pair
    participant ProtectionToken as Protection Token
    participant SystemContract as System Contract<br/>(Kopli)

    Note over User, SystemContract: Phase 1: System Setup and Configuration
    
    User->>CallbackContract: Deploy AmmalgamProtectionCallback
    User->>ReactiveContract: Deploy AmmalgamProtectionReactive
    User->>ReactiveContract: addMonitoredPair(pairAddress)
    ReactiveContract->>SystemContract: Subscribe to liquidation events
    ReactiveContract->>SystemContract: Subscribe to position change events
    ReactiveContract->>SystemContract: Subscribe to CRON events

    Note over User, SystemContract: Phase 2: User Subscription to Protection
    
    User->>ProtectionToken: approve(callbackContract, maxAmount)
    Note over User: User must approve tokens for automatic protection
    
    User->>CallbackContract: subscribeToProtection(pair, type, threshold, target, asset, maxAmount)
    CallbackContract->>AmmalgamPair: getInputParams(user, false)
    AmmalgamPair-->>CallbackContract: Verify user has borrowing position
    CallbackContract->>CallbackContract: Store protection configuration
    CallbackContract-->>User: emit UserSubscribed

    Note over User, SystemContract: Phase 3: Periodic Monitoring (Main Loop)
    
    SystemContract->>ReactiveContract: CRON Event (every 5 minutes)
    ReactiveContract->>ReactiveContract: react(cronLog)
    ReactiveContract->>CallbackContract: checkAndProtectPositions()
    
    loop For Each Active User
        CallbackContract->>AmmalgamPair: getInputParams(user, true)
        AmmalgamPair-->>CallbackContract: Current position data
        
        CallbackContract->>CallbackContract: _analyzePosition(user, pair)
        Note over CallbackContract: Calculate Health Factor, Leverage Ratio,<br/>Risk Type (Hard/Soft/Leverage), Position Age
        
        alt Health Factor Below Threshold
            CallbackContract->>CallbackContract: _executeProtection()
            
            alt Protection Type: COLLATERAL_ONLY
                CallbackContract->>ProtectionToken: transferFrom(user, contract, amount)
                CallbackContract->>ProtectionToken: transfer(pair, amount)
                CallbackContract->>AmmalgamPair: deposit(user)
                CallbackContract-->>ReactiveContract: emit ProtectionExecuted
                
            else Protection Type: DEBT_REPAYMENT_ONLY
                CallbackContract->>ProtectionToken: transferFrom(user, contract, amount)
                CallbackContract->>ProtectionToken: transfer(pair, amount)
                
                alt Leverage Risk + Has Liquidity Debt
                    CallbackContract->>AmmalgamPair: repayLiquidity(user)
                else Standard Debt Repayment
                    CallbackContract->>AmmalgamPair: repay(user)
                end
                
                CallbackContract-->>ReactiveContract: emit ProtectionExecuted
            end
            
        else Health Factor Above Threshold
            Note over CallbackContract: No protection needed - position safe
        end
    end
    
    CallbackContract-->>ReactiveContract: emit ProtectionCycleCompleted(timestamp, checked, executed, failed)
    ReactiveContract->>ReactiveContract: processingActive = false

    Note over User, SystemContract: Phase 4: Real-time Emergency Response (Liquidation Event)

    AmmalgamPair-->>ReactiveContract: Liquidation Event Detected
    ReactiveContract->>ReactiveContract: react(liquidationLog)
    ReactiveContract->>ReactiveContract: Extract borrower from event (topic_1)
    ReactiveContract->>CallbackContract: emergencyProtectionCheck(borrower, pair)
    
    CallbackContract->>CallbackContract: _isUserSubscribedToPair(borrower, pair)
    
    alt Borrower IS Subscribed
        CallbackContract->>CallbackContract: _checkAndProtectUser(borrower, pair, isEmergency=true)
        Note over CallbackContract: Skip cooldown for emergency<br/>Use 1-minute interval instead of 5-minute
        
        CallbackContract->>AmmalgamPair: getInputParams(borrower, true)
        AmmalgamPair-->>CallbackContract: Current position status
        
        alt Position Still At Risk After Liquidation
            CallbackContract->>CallbackContract: Execute immediate protection
            CallbackContract-->>ReactiveContract: emit EmergencyProtectionExecuted
        else Position Now Safe
            Note over CallbackContract: No additional protection needed
        end
        
    else Borrower NOT Subscribed
        CallbackContract->>CallbackContract: stats.skippedNonSubscribers++
        CallbackContract-->>ReactiveContract: emit NonSubscriberSkipped(borrower, pair, "User not subscribed")
        Note over CallbackContract: Skip protection - save gas<br/>No point protecting non-subscribers
    end
    
    CallbackContract-->>ReactiveContract: emit ProtectionCycleCompleted(timestamp, checked, executed, failed)

    Note over User, SystemContract: Phase 5: Position Change Response (Risk Events)

    User->>AmmalgamPair: borrow() / withdraw() [Risk Increasing]
    AmmalgamPair-->>ReactiveContract: Borrow/Withdraw Event
    ReactiveContract->>ReactiveContract: react(positionChangeLog)
    ReactiveContract->>ReactiveContract: Extract user from event (topic_1)
    ReactiveContract->>CallbackContract: emergencyProtectionCheck(user, pair)
    
    CallbackContract->>CallbackContract: _isUserSubscribedToPair(user, pair)
    
    alt User IS Subscribed
        CallbackContract->>CallbackContract: Check user position for risk increase
        Note over CallbackContract: Higher priority for risk-increasing events
        
        alt User Position Now At Risk
            CallbackContract->>CallbackContract: Execute protection immediately
            CallbackContract-->>ReactiveContract: emit ProtectionExecuted
        end
        
    else User NOT Subscribed
        CallbackContract->>CallbackContract: stats.skippedNonSubscribers++
        CallbackContract-->>ReactiveContract: emit NonSubscriberSkipped(user, pair, "User not subscribed")
        Note over CallbackContract: Skip - user hasn't opted into protection
    end

    User->>AmmalgamPair: repay() / deposit() [Risk Decreasing]
    AmmalgamPair-->>ReactiveContract: Repay/Deposit Event
    ReactiveContract->>ReactiveContract: react(riskDecreasingLog)
    Note over ReactiveContract: Lower priority check<br/>with longer cooldown
    ReactiveContract->>ReactiveContract: Extract user from event (topic_1)
    ReactiveContract->>CallbackContract: emergencyProtectionCheck(user, pair)
    
    CallbackContract->>CallbackContract: _isUserSubscribedToPair(user, pair)
    
    alt User IS Subscribed
        CallbackContract->>CallbackContract: Verify position improvement
        Note over CallbackContract: Confirm risk actually decreased
    else User NOT Subscribed
        CallbackContract-->>ReactiveContract: emit NonSubscriberSkipped(user, pair, "User not subscribed")
    end

    Note over User, SystemContract: Phase 6: User Management and Monitoring

    User->>CallbackContract: getUserProtection(user, pair)
    CallbackContract-->>User: Return protection configuration and stats
    
    User->>CallbackContract: isUserSubscribed(user, pair)
    CallbackContract-->>User: Return subscription status
    
    User->>CallbackContract: getSystemHealth()
    CallbackContract-->>User: Return stats including skippedNonSubscribers
    
    User->>CallbackContract: unsubscribeFromProtection(pair)
    CallbackContract->>CallbackContract: Remove protection and cleanup
    CallbackContract-->>User: emit UserUnsubscribed

    Note over User, SystemContract: Emergency Recovery

    alt System Gets Stuck
        User->>ReactiveContract: resetProcessingFlag()
        ReactiveContract->>ReactiveContract: processingActive = false
        Note over ReactiveContract: Emergency recovery function
    end
    
    alt Manual Testing
        User->>ReactiveContract: forceUserCheck(user, pair)
        ReactiveContract->>CallbackContract: emergencyProtectionCheck(user, pair)
        Note over ReactiveContract: Manual trigger for testing
    end
