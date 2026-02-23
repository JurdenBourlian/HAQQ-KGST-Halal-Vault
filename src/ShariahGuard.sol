// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IShariahOracle.sol";

contract ShariahGuard is AccessControl {
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    enum OraclePriority {
        GLOBAL_ONLY,      // Global oracle only
        REGIONAL_FIRST,   // Regional first, fallback to global
        GLOBAL_OVERRIDE,  // Global oracle has final say (DEFAULT)
        HYBRID            // Both must approve
    }

    // ── Struct for packing verdicts (avoids stack too deep) ──────────────
    struct Verdicts {
        bool regionalExists;
        bool regionalOk;
        string regionalReason;
        bool globalExists;
        bool globalOk;
        string globalReason;
    }

    IShariahOracle public globalOracle;
    mapping(bytes32 => IShariahOracle) public regionalOracles;

    bool public enabled = true;
    bool public emergencyMode;
    uint256 public maxOracleAge = 24 hours;
    uint256 public constant EMERGENCY_STALE_THRESHOLD = 48 hours;
    
    OraclePriority public oraclePriority = OraclePriority.GLOBAL_OVERRIDE;

    error ShariahViolation(string reason);
    error OracleError(address oracle);
    error OracleStale(address oracle, uint256 lastUpdated, uint256 maxAge);
    error InvalidPriority();

    event GlobalOracleUpdated(address indexed oracle);
    event RegionalOracleSet(bytes32 indexed regionId, address indexed oracle);
    event ComplianceResult(address indexed user, bool allowed, string source);
    event EmergencyModeToggled(bool enabled);
    event MaxOracleAgeUpdated(uint256 newAge);
    event OraclePriorityUpdated(OraclePriority newPriority);
    event RegionalOverruled(bytes32 indexed regionId, address indexed user, string reason);

    constructor(address _globalOracle) {
        if (_globalOracle != address(0)) {
            globalOracle = IShariahOracle(_globalOracle);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    function checkCompliance(
        address user,
        bytes32 regionId,
        uint256 amount
    ) external {
        if (!enabled || emergencyMode) return;

        Verdicts memory v;
        (v.regionalExists, v.regionalOk, v.regionalReason) = _getRegionalVerdict(user, regionId, amount);
        (v.globalExists, v.globalOk, v.globalReason) = _getGlobalVerdict(user, amount);

        (bool isCompliant, string memory source) = _applyOraclePriority(v, regionId, user);

        if (!isCompliant) {
            revert ShariahViolation(source);
        }
        
        emit ComplianceResult(user, true, source);
    }

    function wouldBeCompliant(
        address user,
        bytes32 regionId,
        uint256 amount
    ) external view returns (bool ok, string memory reason) {
        if (!enabled || emergencyMode) return (true, "bypassed");

        Verdicts memory v;
        (v.regionalExists, v.regionalOk, v.regionalReason) = _simulateRegionalVerdict(user, regionId, amount);
        (v.globalExists, v.globalOk, v.globalReason) = _simulateGlobalVerdict(user, amount);

        (ok, reason) = _simulatePriority(v);
    }

    function _applyOraclePriority(
        Verdicts memory v,
        bytes32 regionId,
        address user
    ) internal returns (bool, string memory) {
        
        if (oraclePriority == OraclePriority.GLOBAL_ONLY) {
            if (!v.globalExists) return (true, "no-global-fallback");
            if (v.globalOk) return (true, "global");
            return (false, "global-rejected");
        }

        if (oraclePriority == OraclePriority.GLOBAL_OVERRIDE) {
            if (v.globalExists && !v.globalOk) {
                if (v.regionalExists && v.regionalOk) {
                    emit RegionalOverruled(regionId, user, "Global override");
                }
                return (false, "global-override");
            }
            if (v.regionalExists) {
                return (v.regionalOk, v.regionalOk ? "regional" : "regional-rejected");
            }
            if (v.globalExists) {
                return (v.globalOk, v.globalOk ? "global" : "global-rejected");
            }
            return (true, "no-oracles");
        }

        if (oraclePriority == OraclePriority.REGIONAL_FIRST) {
            if (v.regionalExists) {
                if (!v.regionalOk) return (false, "regional-rejected");
                if (v.globalExists && !v.globalOk) {
                    emit RegionalOverruled(regionId, user, "Global veto");
                    return (false, "global-veto");
                }
                return (true, "regional-approved");
            }
            if (v.globalExists) return (v.globalOk, v.globalOk ? "global" : "global-rejected");
            return (true, "no-oracles");
        }

        // HYBRID — both oracles must approve
        if (v.regionalExists && !v.regionalOk) return (false, "regional-rejected");
        if (v.globalExists && !v.globalOk) return (false, "global-rejected");
        return (true, "hybrid-approval");
    }

    function _simulatePriority(
        Verdicts memory v
    ) internal view returns (bool, string memory) {
        
        if (oraclePriority == OraclePriority.GLOBAL_ONLY) {
            if (!v.globalExists) return (true, "no-global-fallback");
            if (v.globalOk) return (true, "global");
            return (false, "global-rejected");
        }

        if (oraclePriority == OraclePriority.GLOBAL_OVERRIDE) {
            if (v.globalExists && !v.globalOk) {
                return (false, "global-override");
            }
            if (v.regionalExists) {
                return (v.regionalOk, v.regionalOk ? "regional" : v.regionalReason);
            }
            if (v.globalExists) {
                return (v.globalOk, v.globalOk ? "global" : v.globalReason);
            }
            return (true, "no-oracles");
        }

        if (oraclePriority == OraclePriority.REGIONAL_FIRST) {
            if (v.regionalExists) {
                if (!v.regionalOk) return (false, v.regionalReason);
                if (v.globalExists && !v.globalOk) return (false, "global-veto");
                return (true, "regional-approved");
            }
            if (v.globalExists) return (v.globalOk, v.globalOk ? "global" : v.globalReason);
            return (true, "no-oracles");
        }

        // HYBRID
        if (v.regionalExists && !v.regionalOk) return (false, v.regionalReason);
        if (v.globalExists && !v.globalOk) return (false, v.globalReason);
        return (true, "hybrid-approval");
    }

    function _getRegionalVerdict(address user, bytes32 regionId, uint256 amount) 
        internal 
        returns (bool exists, bool ok, string memory reason) 
    {
        IShariahOracle regional = regionalOracles[regionId];
        if (address(regional) == address(0)) {
            return (false, false, "no-regional");
        }
        
        uint256 last = _safeLastUpdated(regional);
        if (last != 0) {
            uint256 age = block.timestamp - last;
            if (age > EMERGENCY_STALE_THRESHOLD) {
                if (!emergencyMode) {
                    emergencyMode = true;
                    emit EmergencyModeToggled(true);
                }
                return (true, true, "emergency-bypass");
            }
            if (age > maxOracleAge) {
                revert OracleStale(address(regional), last, maxOracleAge);
            }
        }

        try regional.isCompliant(user, amount) returns (bool r) {
            return (true, r, r ? "regional-ok" : "regional-rejected");
        } catch {
            revert OracleError(address(regional));
        }
    }

    function _getGlobalVerdict(address user, uint256 amount)
        internal
        returns (bool exists, bool ok, string memory reason)
    {
        if (address(globalOracle) == address(0)) {
            return (false, false, "no-global");
        }
        
        uint256 last = _safeLastUpdated(globalOracle);
        if (last != 0) {
            uint256 age = block.timestamp - last;
            if (age > EMERGENCY_STALE_THRESHOLD) {
                if (!emergencyMode) {
                    emergencyMode = true;
                    emit EmergencyModeToggled(true);
                }
                return (true, true, "emergency-bypass");
            }
            if (age > maxOracleAge) {
                revert OracleStale(address(globalOracle), last, maxOracleAge);
            }
        }

        try globalOracle.isCompliant(user, amount) returns (bool r) {
            return (true, r, r ? "global-ok" : "global-rejected");
        } catch {
            revert OracleError(address(globalOracle));
        }
    }

    function _simulateRegionalVerdict(address user, bytes32 regionId, uint256 amount) 
        internal 
        view 
        returns (bool exists, bool ok, string memory reason) 
    {
        IShariahOracle regional = regionalOracles[regionId];
        if (address(regional) == address(0)) {
            return (false, false, "no-regional");
        }
        
        uint256 last = _safeLastUpdated(regional);
        if (last != 0 && block.timestamp - last > maxOracleAge) {
            return (true, false, "regional-stale");
        }

        try regional.isCompliant(user, amount) returns (bool r) {
            return (true, r, r ? "regional-ok" : "regional-rejected");
        } catch {
            return (true, false, "regional-error");
        }
    }

    function _simulateGlobalVerdict(address user, uint256 amount)
        internal
        view
        returns (bool exists, bool ok, string memory reason)
    {
        if (address(globalOracle) == address(0)) {
            return (false, false, "no-global");
        }
        
        uint256 last = _safeLastUpdated(globalOracle);
        if (last != 0 && block.timestamp - last > maxOracleAge) {
            return (true, false, "global-stale");
        }

        try globalOracle.isCompliant(user, amount) returns (bool r) {
            return (true, r, r ? "global-ok" : "global-rejected");
        } catch {
            return (true, false, "global-error");
        }
    }

    function _safeLastUpdated(IShariahOracle oracle) internal view returns (uint256) {
        try oracle.lastUpdated() returns (uint256 t) {
            return t;
        } catch {
            return 0;
        }
    }

    // ── ADMIN FUNCTIONS ───────────────────────────────────────────────────

    function setGlobalOracle(address _oracle) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(_oracle != address(0), "ShariahGuard: zero address");
        globalOracle = IShariahOracle(_oracle);
        emit GlobalOracleUpdated(_oracle);
    }

    function removeGlobalOracle() external onlyRole(ORACLE_ADMIN_ROLE) {
        globalOracle = IShariahOracle(address(0));
        emit GlobalOracleUpdated(address(0));
    }

    function setRegionalOracle(bytes32 regionId, address _oracle) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(regionId != bytes32(0), "ShariahGuard: invalid region");
        require(_oracle != address(0), "ShariahGuard: zero address");
        regionalOracles[regionId] = IShariahOracle(_oracle);
        emit RegionalOracleSet(regionId, _oracle);
    }

    function removeRegionalOracle(bytes32 regionId) external onlyRole(ORACLE_ADMIN_ROLE) {
        delete regionalOracles[regionId];
        emit RegionalOracleSet(regionId, address(0));
    }

    function setOraclePriority(OraclePriority _priority) 
        external 
        onlyRole(ORACLE_ADMIN_ROLE) 
    {
        if (uint8(_priority) > 3) revert InvalidPriority();
        oraclePriority = _priority;
        emit OraclePriorityUpdated(_priority);
    }

    function setEnabled(bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = _enabled;
    }

    function setEmergencyMode(bool _emergency) external onlyRole(GUARDIAN_ROLE) {
        emergencyMode = _emergency;
        emit EmergencyModeToggled(_emergency);
    }

    function setMaxOracleAge(uint256 _age) external onlyRole(ORACLE_ADMIN_ROLE) {
        require(_age >= 1 hours, "ShariahGuard: age too short");
        require(_age <= 7 days, "ShariahGuard: age too long");
        maxOracleAge = _age;
        emit MaxOracleAgeUpdated(_age);
    }
}
