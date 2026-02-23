// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ShariahGuard.sol";
import "./mocks/MockShariahOracle.sol";

contract ShariahGuardTest is Test {
    event ComplianceResult(address indexed user, bool allowed, string source);
    event RegionalOverruled(bytes32 indexed regionId, address indexed user, string reason);

    ShariahGuard public guard;
    MockShariahOracle public globalOracle;
    MockShariahOracle public regionalOracle;
    address public user = address(0x100);
    bytes32 public constant KG_REGION = keccak256("KG");

    function setUp() public {
        globalOracle = new MockShariahOracle(true);
        guard = new ShariahGuard(address(globalOracle));
        regionalOracle = new MockShariahOracle(true);
        guard.setRegionalOracle(KG_REGION, address(regionalOracle));
    }

    // Tests for GLOBAL_OVERRIDE mode

    function testGlobalOverride_RegionalYes_GlobalNo() public {
        // Regional returns true, global returns false
        MockShariahOracle rejectingGlobal = new MockShariahOracle(false);
        guard.setGlobalOracle(address(rejectingGlobal));
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);

        vm.expectRevert(
            abi.encodeWithSelector(ShariahGuard.ShariahViolation.selector, "global-override")
        );
        guard.checkCompliance(user, KG_REGION, 100e18);
    }

    function testGlobalOverride_RegionalYes_GlobalYes() public {
        // Both return true
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);

        vm.expectEmit(true, true, true, true);
        emit ComplianceResult(user, true, "regional");
        guard.checkCompliance(user, KG_REGION, 100e18);
    }

    function testGlobalOverride_RegionalNo_GlobalYes() public {
        // Regional returns false, global returns true
        MockShariahOracle rejectingRegional = new MockShariahOracle(false);
        guard.setRegionalOracle(KG_REGION, address(rejectingRegional));
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);

        vm.expectRevert(
            abi.encodeWithSelector(ShariahGuard.ShariahViolation.selector, "regional-rejected")
        );
        guard.checkCompliance(user, KG_REGION, 100e18);
    }

    function testGlobalOverride_NoRegional_GlobalYes() public {
        // No regional oracle, global returns true
        guard.removeRegionalOracle(KG_REGION);
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);

        guard.checkCompliance(user, KG_REGION, 100e18); // Should pass via global oracle
    }

    function testGlobalOverride_NoRegional_GlobalNo() public {
        // No regional oracle, global returns false
        MockShariahOracle rejectingGlobal = new MockShariahOracle(false);
        guard.setGlobalOracle(address(rejectingGlobal));
        guard.removeRegionalOracle(KG_REGION);
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);

        vm.expectRevert(
            abi.encodeWithSelector(ShariahGuard.ShariahViolation.selector, "global-override")
        );
        guard.checkCompliance(user, KG_REGION, 100e18);
    }

    function testGlobalOverride_RegionalOverruledEvent() public {
        // Verify that override event is emitted
        MockShariahOracle rejectingGlobal = new MockShariahOracle(false);
        guard.setGlobalOracle(address(rejectingGlobal));
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);

        vm.expectEmit(true, true, true, true);
        emit RegionalOverruled(KG_REGION, user, "Global override");
        
        try guard.checkCompliance(user, KG_REGION, 100e18) {
            fail("Should have reverted");
        } catch {}
    }

    // Tests for other modes

    function testGlobalOnlyMode() public {
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_ONLY);
        
        // Regional oracle is ignored
        MockShariahOracle rejectingRegional = new MockShariahOracle(false);
        guard.setRegionalOracle(KG_REGION, address(rejectingRegional));
        
        guard.checkCompliance(user, KG_REGION, 100e18); // Passes via global oracle (which returns true)
    }

    function testRegionalFirstMode() public {
        guard.setOraclePriority(ShariahGuard.OraclePriority.REGIONAL_FIRST);
        
        MockShariahOracle regionalYes = new MockShariahOracle(true);
        MockShariahOracle globalNo = new MockShariahOracle(false);
        
        guard.setRegionalOracle(KG_REGION, address(regionalYes));
        guard.setGlobalOracle(address(globalNo));
        
        vm.expectRevert(
            abi.encodeWithSelector(ShariahGuard.ShariahViolation.selector, "global-veto")
        );
        guard.checkCompliance(user, KG_REGION, 100e18);
    }

    function testHybridMode() public {
        guard.setOraclePriority(ShariahGuard.OraclePriority.HYBRID);
        
        MockShariahOracle regionalYes = new MockShariahOracle(true);
        MockShariahOracle globalNo = new MockShariahOracle(false);
        
        guard.setRegionalOracle(KG_REGION, address(regionalYes));
        guard.setGlobalOracle(address(globalNo));
        
        vm.expectRevert(
            abi.encodeWithSelector(ShariahGuard.ShariahViolation.selector, "global-rejected")
        );
        guard.checkCompliance(user, KG_REGION, 100e18);
    }

    function testWouldBeCompliant_GlobalOverride() public {
        guard.setOraclePriority(ShariahGuard.OraclePriority.GLOBAL_OVERRIDE);
        
        (bool ok, string memory reason) = guard.wouldBeCompliant(user, KG_REGION, 100e18);
        assertTrue(ok);
        assertEq(reason, "regional");
    }
}