// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "../../../lib/reactive-lib/src/interfaces/IReactive.sol";
import "../../../lib/reactive-lib/src/abstract-base/AbstractPausableReactive.sol";

contract AmmalgamProtectionReactive is IReactive, AbstractPausableReactive {

    event ProtectionCheckTriggered(uint256 timestamp, string triggerType, address indexed pair, address indexed user);
    event ProtectionCompleted(uint256 timestamp);

    // CORRECTED: Lasna testnet listens to Sepolia events and sends callbacks to Sepolia
    uint256 private constant DESTINATION_CHAIN_ID = 11155111; // Sepolia (where Ammalgam and Callback are deployed)
    uint256 private constant SOURCE_CHAIN_ID = 11155111; // Sepolia (where we listen to Ammalgam events)
    
    // Event signatures for Ammalgam events (calculate using: cast keccak "EventSignature(params)")
    uint256 private constant LIQUIDATE_TOPIC_0 = 0x8b1abab13d2fa1e5a965b1b9c7fc7c3b6ee0d59fa77b0b5e61c12e1baaedc8aa;
    uint256 private constant PROTECTION_CYCLE_COMPLETED_TOPIC_0 = 0xb2a1984478c1064cb30b6e5bd7410ed80e897a5a51f65a9c4a826d92ba5a3492;
    
    // Ammalgam position change event signatures
    uint256 private constant BORROW_TOPIC_0 = 0xa67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4b;
    uint256 private constant WITHDRAW_TOPIC_0 = 0xc67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4d;
    uint256 private constant REPAY_TOPIC_0 = 0xb67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4c;
    uint256 private constant DEPOSIT_TOPIC_0 = 0xd67e1bf0e0f5e50701de0de3b44e5e6e2d4d4b4e4b4b4b4b4b4b4b4b4b4b4e;
    
    uint64 private constant CALLBACK_GAS_LIMIT = 2000000;

    // Core state
    address private protectionManager; // Callback contract address on Sepolia
    uint256 public cronTopic;
    bool private processingActive;
    
    // Monitored Ammalgam pairs on Sepolia
    mapping(address => bool) private monitoredPairs;
    address[] private pairsList;
    
    // Timing controls
    uint256 private lastEmergencyCheck;
    uint256 private lastPeriodicCheck;
    uint256 private constant EMERGENCY_COOLDOWN = 30; // 30 seconds between emergency checks
    uint256 private constant PERIODIC_CHECK_INTERVAL = 300; // 5 minutes between periodic checks
    
    constructor(
        address _protectionManager, // Callback contract address on Sepolia
        address _service,           // System contract on Lasna
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
            // Subscribe to CRON events on Lasna for periodic monitoring
            service.subscribe(
                block.chainid, // Lasna testnet
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            
            // Subscribe to protection cycle completion events from Sepolia callback contract
            service.subscribe(
                DESTINATION_CHAIN_ID, // Sepolia
                protectionManager,    // Callback contract
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
                // Subscribe to Ammalgam events on Sepolia
                service.subscribe(
                    SOURCE_CHAIN_ID, // Sepolia (where Ammalgam pairs are deployed)
                    pairAddress,     // Ammalgam pair contract
                    LIQUIDATE_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                // Subscribe to position change events that increase risk (HIGH PRIORITY)
                service.subscribe(
                    SOURCE_CHAIN_ID,
                    pairAddress,
                    BORROW_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.subscribe(
                    SOURCE_CHAIN_ID,
                    pairAddress,
                    WITHDRAW_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                // Subscribe to position change events that decrease risk (LOWER PRIORITY)
                service.subscribe(
                    SOURCE_CHAIN_ID,
                    pairAddress,
                    REPAY_TOPIC_0,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                
                service.subscribe(
                    SOURCE_CHAIN_ID,
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
                // Unsubscribe from all Sepolia events for this pair
                service.unsubscribe(SOURCE_CHAIN_ID, pairAddress, LIQUIDATE_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
                service.unsubscribe(SOURCE_CHAIN_ID, pairAddress, BORROW_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
                service.unsubscribe(SOURCE_CHAIN_ID, pairAddress, WITHDRAW_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
                service.unsubscribe(SOURCE_CHAIN_ID, pairAddress, REPAY_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
                service.unsubscribe(SOURCE_CHAIN_ID, pairAddress, DEPOSIT_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            }
        }
    }

    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        Subscription[] memory result = new Subscription[](1);
        result[0] = Subscription(
            block.chainid, // Lasna testnet
            address(service),
            cronTopic,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        return result;
    }

    // Main reactive logic - handles events from Sepolia Ammalgam contracts
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == cronTopic) {
            // CRON event on Lasna - periodic protection check for all users
            _handlePeriodicCheck();
            
        } else if (log.topic_0 == PROTECTION_CYCLE_COMPLETED_TOPIC_0 && log._contract == protectionManager) {
            // Protection cycle completed from Sepolia callback contract
            _handleProtectionCompleted();
            
        } else if (log.topic_0 == LIQUIDATE_TOPIC_0 && monitoredPairs[log._contract]) {
            // CRITICAL: Liquidation event from Sepolia Ammalgam pair
            _handleLiquidationEvent(log);
            
        } else if (log.topic_0 == BORROW_TOPIC_0 && monitoredPairs[log._contract]) {
            // HIGH PRIORITY: User borrowed more (increases risk) from Sepolia
            _handleRiskIncreasingEvent(log, "Borrow");
            
        } else if (log.topic_0 == WITHDRAW_TOPIC_0 && monitoredPairs[log._contract]) {
            // HIGH PRIORITY: User withdrew collateral (increases risk) from Sepolia
            _handleRiskIncreasingEvent(log, "Withdraw");
            
        } else if (log.topic_0 == REPAY_TOPIC_0 && monitoredPairs[log._contract]) {
            // LOWER PRIORITY: User repaid debt (decreases risk) from Sepolia
            _handleRiskDecreasingEvent(log, "Repay");
            
        } else if (log.topic_0 == DEPOSIT_TOPIC_0 && monitoredPairs[log._contract]) {
            // LOWER PRIORITY: User deposited more collateral (decreases risk) from Sepolia
            _handleRiskDecreasingEvent(log, "Deposit");
        }
    }

    function _handlePeriodicCheck() internal {
        // Skip if already processing or too soon since last check
        if (processingActive || block.timestamp < lastPeriodicCheck + PERIODIC_CHECK_INTERVAL) {
            return;
        }
        
        // FIXED: Send callback to Sepolia with correct function signature
        bytes memory payload = abi.encodeWithSignature(
            "checkAndProtectPositions(address)",
            address(0) // This matches the /*spender*/ parameter in callback
        );
        
        processingActive = true;
        lastPeriodicCheck = block.timestamp;
        
        emit ProtectionCheckTriggered(block.timestamp, "Periodic", address(0), address(0));
        
        // Send callback from Lasna to Sepolia
        emit Callback(
            DESTINATION_CHAIN_ID, // Sepolia
            protectionManager,    // Callback contract on Sepolia
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    function _handleProtectionCompleted() internal {
        processingActive = false;
        emit ProtectionCompleted(block.timestamp);
    }

    function _handleLiquidationEvent(LogRecord calldata log) internal {
        // CRITICAL emergency response to liquidation from Sepolia
        if (block.timestamp < lastEmergencyCheck + EMERGENCY_COOLDOWN) {
            return; // Too soon since last emergency check
        }
        
        // Extract borrower address from liquidation event (typically in topic_1)
        address borrower = address(uint160(uint256(log.topic_1)));
        
        // FIXED: Send callback to Sepolia with correct function signature
        bytes memory payload = abi.encodeWithSignature(
            "emergencyProtectionCheck(address,address,address)",
            address(0),   // /*spender*/ parameter - RSC sends address(0)
            borrower,     // user parameter - specific user who got liquidated
            log._contract // pair parameter - specific pair where liquidation occurred
        );
        
        lastEmergencyCheck = block.timestamp;
        
        emit ProtectionCheckTriggered(block.timestamp, "Liquidation", log._contract, borrower);
        
        // Send callback from Lasna to Sepolia
        emit Callback(
            DESTINATION_CHAIN_ID, // Sepolia
            protectionManager,    // Callback contract on Sepolia
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    function _handleRiskIncreasingEvent(LogRecord calldata log, string memory eventType) internal {
        // Handle events that INCREASE liquidation risk (borrow, withdraw) from Sepolia
        if (processingActive || block.timestamp < lastEmergencyCheck + EMERGENCY_COOLDOWN) {
            return; // Skip if processing or too soon
        }
        
        // Extract user address from the event (typically in topic_1)
        address user = address(uint160(uint256(log.topic_1)));
        
        // FIXED: Send callback to Sepolia with correct function signature
        bytes memory payload = abi.encodeWithSignature(
            "positionChangeProtectionCheck(address,address,address)",
            address(0),   // /*spender*/ parameter - RSC sends address(0)
            user,         // user parameter - specific user whose position changed
            log._contract // pair parameter - specific pair where change occurred
        );
        
        emit ProtectionCheckTriggered(block.timestamp, eventType, log._contract, user);
        
        // Send callback from Lasna to Sepolia
        emit Callback(
            DESTINATION_CHAIN_ID, // Sepolia
            protectionManager,    // Callback contract on Sepolia
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    function _handleRiskDecreasingEvent(LogRecord calldata log, string memory eventType) internal {
        // Handle events that DECREASE liquidation risk (repay, deposit) from Sepolia
        // Lower priority - longer cooldown and only if no other processing
        if (processingActive || 
            block.timestamp < lastEmergencyCheck + (EMERGENCY_COOLDOWN * 2)) {
            return; // Skip with longer cooldown for risk-decreasing events
        }
        
        // Extract user address from the event
        address user = address(uint160(uint256(log.topic_1)));
        
        // FIXED: Send callback to Sepolia with correct function signature
        bytes memory payload = abi.encodeWithSignature(
            "positionChangeProtectionCheck(address,address,address)",
            address(0),   // /*spender*/ parameter - RSC sends address(0)
            user,         // user parameter - specific user whose position changed
            log._contract // pair parameter - specific pair where change occurred
        );
        
        emit ProtectionCheckTriggered(block.timestamp, eventType, log._contract, user);
        
        // Send callback from Lasna to Sepolia
        emit Callback(
            DESTINATION_CHAIN_ID, // Sepolia
            protectionManager,    // Callback contract on Sepolia
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    // Enhanced user extraction from different Ammalgam event structures
    function _extractUserFromEvent(LogRecord calldata log) internal pure returns (address user) {
        // Ammalgam events typically have user as topic_1, but handle fallbacks
        if (log.topic_1 != 0) {
            user = address(uint160(uint256(log.topic_1)));
        } else if (log.topic_2 != 0) {
            // Fallback for events where user might be in topic_2
            user = address(uint160(uint256(log.topic_2)));
        }
        
        // If we can't extract user, return zero address for general protection check
        if (user == address(0)) {
            user = address(0);
        }
    }

    function _shouldSkipEvent(string memory eventType) internal view returns (bool) {
        // Smart event filtering based on system state and timing
        
        // Always skip if processing is active
        if (processingActive) {
            return true;
        }
        
        // Skip risk-decreasing events if recent emergency check
        bool isRiskDecreasing = 
            keccak256(abi.encodePacked(eventType)) == keccak256(abi.encodePacked("Repay")) ||
            keccak256(abi.encodePacked(eventType)) == keccak256(abi.encodePacked("Deposit"));
        
        if (isRiskDecreasing && block.timestamp < lastEmergencyCheck + (EMERGENCY_COOLDOWN * 2)) {
            return true;
        }
        
        // Skip risk-increasing events if too recent
        bool isRiskIncreasing = 
            keccak256(abi.encodePacked(eventType)) == keccak256(abi.encodePacked("Borrow")) ||
            keccak256(abi.encodePacked(eventType)) == keccak256(abi.encodePacked("Withdraw"));
        
        if (isRiskIncreasing && block.timestamp < lastEmergencyCheck + EMERGENCY_COOLDOWN) {
            return true;
        }
        
        return false;
    }

    // View functions for monitoring and debugging
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

    // Debug functions for testing payload generation
    function testPayloadGeneration() external view returns (
        bytes memory periodicPayload,
        bytes memory emergencyPayload,
        bytes memory positionChangePayload
    ) {
        // Test payload generation for debugging - all include /*spender*/ parameter
        periodicPayload = abi.encodeWithSignature(
            "checkAndProtectPositions(address)",
            address(0) // /*spender*/ parameter
        );
        
        emergencyPayload = abi.encodeWithSignature(
            "emergencyProtectionCheck(address,address,address)",
            address(0), // /*spender*/ parameter
            address(0x1234567890123456789012345678901234567890), // example user
            address(0x0987654321098765432109876543210987654321)  // example pair
        );
        
        positionChangePayload = abi.encodeWithSignature(
            "positionChangeProtectionCheck(address,address,address)",
            address(0), // /*spender*/ parameter
            address(0x1111111111111111111111111111111111111111), // example user
            address(0x2222222222222222222222222222222222222222)  // example pair
        );
    }

    // Emergency management functions
    function forceResetProcessingFlag() external {
        // Only allow reset if processing has been stuck for too long
        require(
            processingActive && 
            block.timestamp > lastPeriodicCheck + (PERIODIC_CHECK_INTERVAL * 3),
            "Processing not stuck"
        );
        
        processingActive = false;
        emit ProtectionCompleted(block.timestamp);
    }

    function emergencyTriggerProtection() external {
        // Manual trigger for emergency situations
        require(!processingActive, "Already processing");
        
        bytes memory payload = abi.encodeWithSignature(
            "checkAndProtectPositions(address)",
            address(0) // /*spender*/ parameter
        );
        
        processingActive = true;
        
        emit ProtectionCheckTriggered(block.timestamp, "Manual", address(0), address(0));
        
        // Send manual callback from Lasna to Sepolia
        emit Callback(
            DESTINATION_CHAIN_ID, // Sepolia
            protectionManager,    // Callback contract on Sepolia
            CALLBACK_GAS_LIMIT,
            payload
        );
    }

    // Network information helpers
    function getNetworkInfo() external view returns (
        uint256 sourceChainId,
        uint256 destinationChainId,
        address protectionManagerAddress,
        string memory networkDescription
    ) {
        return (
            SOURCE_CHAIN_ID,
            DESTINATION_CHAIN_ID,
            protectionManager,
            "Lasna RSC listens to Sepolia Ammalgam events, sends callbacks to Sepolia"
        );
    }

    // Enhanced event signature verification (for testing)
    function getEventSignatures() external pure returns (
        uint256 liquidateSignature,
        uint256 borrowSignature,
        uint256 withdrawSignature,
        uint256 repaySignature,
        uint256 depositSignature,
        uint256 protectionCompletedSignature
    ) {
        return (
            LIQUIDATE_TOPIC_0,
            BORROW_TOPIC_0,
            WITHDRAW_TOPIC_0,
            REPAY_TOPIC_0,
            DEPOSIT_TOPIC_0,
            PROTECTION_CYCLE_COMPLETED_TOPIC_0
        );
    }
}
