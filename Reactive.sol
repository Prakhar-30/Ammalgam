// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "../../../lib/reactive-lib/src/interfaces/IReactive.sol";
import "../../../lib/reactive-lib/src/abstract-base/AbstractPausableReactive.sol";

contract AmmalgamProtectionReactive is IReactive, AbstractPausableReactive {

    event ProtectionCheckTriggered(uint256 timestamp, string triggerType, address indexed pair, address indexed user);
    event ProtectionCompleted(uint256 timestamp);

    uint256 private constant DESTINATION_CHAIN_ID = 11155111; // Sepolia
    
    // Event signatures (calculate actual ones using: cast keccak "EventSignature(params)")
    uint256 private constant LIQUIDATE_TOPIC_0 = 0x8b1abab13d2fa1e5a965b1b9c7fc7c3b6ee0d59fa77b0b5e61c12e1baaedc8aa;
    uint256 private constant PROTECTION_CYCLE_COMPLETED_TOPIC_0 = 0xb2a1984478c1064cb30b6e5bd7410ed80e897a5a51f65a9c4a826d92ba5a3492;
    
    // Position change events that affect liquidation risk
    uint256 private constant BORROW_TOPIC_0 = 0xa67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4b;        // User borrows (increases risk)
    uint256 private constant WITHDRAW_TOPIC_0 = 0xc67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4d;      // User withdraws collateral (increases risk)
    uint256 private constant REPAY_TOPIC_0 = 0xb67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4c;         // User repays (decreases risk, lower priority)
    uint256 private constant DEPOSIT_TOPIC_0 = 0xd67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4e;       // User deposits (decreases risk, lower priority)
    
    uint64 private constant CALLBACK_GAS_LIMIT = 2000000;

    // Core state
    address private protectionManager;
    uint256 public cronTopic;
    bool private processingActive;
    
    // Monitored pairs
    mapping(address => bool) private monitoredPairs;
    address[] private pairsList;
    
    // Timing controls
    uint256 private lastEmergencyCheck;
    uint256 private lastPeriodicCheck;
    uint256 private constant EMERGENCY_COOLDOWN = 30; // 30 seconds between emergency checks
    uint256 private constant PERIODIC_CHECK_INTERVAL = 300; // 5 minutes between periodic checks
    
    constructor(
        address _protectionManager,
        address _service,
        uint256 _cronTopic
    ) payable {
        require(_protectionManager != address(0), "Invalid protection manager");
        require(_service != address(0), "Invalid service contract");
        
        service = ISystemContract(payable(_service));
        protectionManager = _protectionManager;
        cronTopic = _cronTopic;
        processingActive = false;
        lastEmergencyCheck = block.timestamp;
        lastPeriodicCheck = block.timestamp;
        
        if (!vm) {
            // Subscribe to CRON events for periodic monitoring
            service.subscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            // Subscribe to protection cycle completion events
            service.subscribe(
                DESTINATION_CHAIN_ID,
                protectionManager,
                PROTECTION_CYCLE_COMPLETED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function addMonitoredPair(address pairAddress) external {
        require(pairAddress != address(0), "Invalid pair address");
        
        if (!monitoredPairs[pairAddress]) {
            monitoredPairs[pairAddress] = true;
            pairsList.push(pairAddress);
            
            if (!vm) {
                // Subscribe to liquidation events from this pair
                service.subscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    LIQUIDATE_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                // Subscribe to position change events that increase risk (HIGH PRIORITY)
                service.subscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    BORROW_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.subscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    WITHDRAW_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                // Subscribe to position change events that decrease risk (LOWER PRIORITY)
                service.subscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    REPAY_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.subscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    DEPOSIT_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }
        }
    }

    function removeMonitoredPair(address pairAddress) external {
        if (monitoredPairs[pairAddress]) {
            monitoredPairs[pairAddress] = false;
            
            // Remove from pairs list
            for (uint256 i = 0; i < pairsList.length; i++) {
                if (pairsList[i] == pairAddress) {
                    pairsList[i] = pairsList[pairsList.length - 1];
                    pairsList.pop();
                    break;
                }
            }
            
            if (!vm) {
                // Unsubscribe from all events for this pair
                service.unsubscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    LIQUIDATE_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.unsubscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    BORROW_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.unsubscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    WITHDRAW_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.unsubscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    REPAY_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.unsubscribe(
                    DESTINATION_CHAIN_ID,
                    pairAddress,
                    DEPOSIT_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }
        }
    }

    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        Subscription[] memory result = new Subscription[](1);
        result[0] = Subscription(
            block.chainid,
            address(service),
            cronTopic,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        return result;
    }

    // Main reactive logic - handles all event types
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == cronTopic) {
            // CRON event - periodic protection check for all users
            _handlePeriodicCheck();
            
        } else if (log.topic_0 == PROTECTION_CYCLE_COMPLETED_TOPIC_0 && log._contract == protectionManager) {
            // Protection cycle completed - reset processing flag
            _handleProtectionCompleted();
            
        } else if (log.topic_0 == LIQUIDATE_TOPIC_0 && monitoredPairs[log._contract]) {
            // CRITICAL: Liquidation event detected - emergency response
            _handleLiquidationEvent(log);
            
        } else if (log.topic_0 == BORROW_TOPIC_0 && monitoredPairs[log._contract]) {
            // HIGH PRIORITY: User borrowed more (increases risk)
            _handleRiskIncreasingEvent(log, "Borrow");
            
        } else if (log.topic_0 == WITHDRAW_TOPIC_0 && monitoredPairs[log._contract]) {
            // HIGH PRIORITY: User withdrew collateral (increases risk)
            _handleRiskIncreasingEvent(log, "Withdraw");
            
        } else if (log.topic_0 == REPAY_TOPIC_0 && monitoredPairs[log._contract]) {
            // LOWER PRIORITY: User repaid debt (decreases risk)
            _handleRiskDecreasingEvent(log, "Repay");
            
        } else if (log.topic_0 == DEPOSIT_TOPIC_0 && monitoredPairs[log._contract]) {
            // LOWER PRIORITY: User deposited more collateral (decreases risk)
            _handleRiskDecreasingEvent(log, "Deposit");
        }
    }

    function _handlePeriodicCheck() internal {
        // Skip if already processing or too soon since last check
        if (processingActive || block.timestamp < lastPeriodicCheck + PERIODIC_CHECK_INTERVAL) {
            return;
        }
        
        // Trigger protection check for ALL users across ALL pairs
        bytes memory payload = abi.encodeWithSignature(
            "checkAndProtectPositions(address)",
            address(0) // Check all users
        );
        
        processingActive = true;
        lastPeriodicCheck = block.timestamp;
        
        emit ProtectionCheckTriggered(block.timestamp, "Periodic", address(0), address(0));
        
        emit Callback(
            DESTINATION_CHAIN_ID,
            protectionManager,
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    function _handleProtectionCompleted() internal {
        processingActive = false;
        emit ProtectionCompleted(block.timestamp);
    }

    function _handleLiquidationEvent(LogRecord calldata log) internal {
        // CRITICAL emergency response to liquidation
        if (block.timestamp < lastEmergencyCheck + EMERGENCY_COOLDOWN) {
            return; // Too soon since last emergency check
        }
        
        // Extract borrower address from liquidation event (typically in topic_1)
        address borrower = address(uint160(uint256(log.topic_1)));
        
        // Call emergency protection check for this specific borrower and pair
        bytes memory payload = abi.encodeWithSignature(
            "emergencyProtectionCheck(address,address)",
            borrower, // Specific user who got liquidated
            log._contract // Specific pair where liquidation occurred
        );
        
        lastEmergencyCheck = block.timestamp;
        
        emit ProtectionCheckTriggered(block.timestamp, "Liquidation", log._contract, borrower);
        
        emit Callback(
            DESTINATION_CHAIN_ID,
            protectionManager,
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    function _handleRiskIncreasingEvent(LogRecord calldata log, string memory eventType) internal {
        // Handle events that INCREASE liquidation risk (borrow, withdraw)
        if (processingActive || block.timestamp < lastEmergencyCheck + EMERGENCY_COOLDOWN) {
            return; // Skip if processing or too soon
        }
        
        // Extract user address from the event (typically in topic_1)
        address user = address(uint160(uint256(log.topic_1)));
        
        // Call position change protection check for this specific user and pair
        bytes memory payload = abi.encodeWithSignature(
            "positionChangeProtectionCheck(address,address)",
            user, // Specific user whose position changed
            log._contract // Specific pair where change occurred
        );
        
        emit ProtectionCheckTriggered(block.timestamp, eventType, log._contract, user);
        
        emit Callback(
            DESTINATION_CHAIN_ID,
            protectionManager,
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    function _handleRiskDecreasingEvent(LogRecord calldata log, string memory eventType) internal {
        // Handle events that DECREASE liquidation risk (repay, deposit)
        // Lower priority - longer cooldown and only if no other processing
        if (processingActive || 
            block.timestamp < lastEmergencyCheck + (EMERGENCY_COOLDOWN * 2)) {
            return; // Skip with longer cooldown for risk-decreasing events
        }
        
        // Extract user address from the event
        address user = address(uint160(uint256(log.topic_1)));
        
        // Call position change protection check (lower priority)
        bytes memory payload = abi.encodeWithSignature(
            "positionChangeProtectionCheck(address,address)",
            user, // Specific user whose position changed
            log._contract // Specific pair where change occurred
        );
        
        emit ProtectionCheckTriggered(block.timestamp, eventType, log._contract, user);
        
        emit Callback(
            DESTINATION_CHAIN_ID,
            protectionManager,
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    // View functions
    function isProcessingActive() external view returns (bool) {
        return processingActive;
    }
    
    function getProtectionManager() external view returns (address) {
        return protectionManager;
    }
    
    function getCronTopic() external view returns (uint256) {
        return cronTopic;
    }
    
    function isPairMonitored(address pairAddress) external view returns (bool) {
        return monitoredPairs[pairAddress];
    }
    
    function getMonitoredPairs() external view returns (address[] memory) {
        return pairsList;
    }
    
    function getMonitoredPairsCount() external view returns (uint256) {
        return pairsList.length;
    }
    
    function getLastEmergencyCheck() external view returns (uint256) {
        return lastEmergencyCheck;
    }
    
    function getLastPeriodicCheck() external view returns (uint256) {
        return lastPeriodicCheck;
    }
    
    function getSystemStatus() external view returns (
        bool isProcessing,
        uint256 monitoredPairsCount,
        uint256 lastEmergency,
        uint256 lastPeriodic
    ) {
        return (
            processingActive,
            pairsList.length,
            lastEmergencyCheck,
            lastPeriodicCheck
        );
    }
}
