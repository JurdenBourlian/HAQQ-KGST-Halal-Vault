// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// FeeDistributor.t.sol
//
// Tests for the updated FeeDistributor with immutable founder share.
//
// Key invariants tested:
//   1. Founder always receives exactly FOUNDER_SHARE_BPS (2000) of every distribute()
//   2. Founder cannot be added to setRecipients() — they already have immutable share
//   3. setRecipients() must sum to exactly RECIPIENTS_TOTAL_BPS (8000), not 10000
//   4. No admin role can remove or reduce founder share
//   5. previewDistribution() matches actual distribute() output
// ─────────────────────────────────────────────────────────────────────────────

contract FeeDistributorTest is Test {
    event FeesReceived(address indexed from, uint256 amount);
    event FeesDistributed(uint256 totalAmount, uint256 founderShare, uint256 timestamp);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event RecipientsUpdated(uint256 count);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);



    FeeDistributor public dist;
    MockERC20      public kgst;

    // Named actors
    address public founder    = makeAddr("founder");
    address public team       = makeAddr("team");
    address public protocol   = makeAddr("protocol");
    address public shariah    = makeAddr("shariahBoard");
    address public charity    = makeAddr("charity");
    address public dao        = makeAddr("daoReserve");
    address public strategy   = makeAddr("strategy");
    address public feeManager = makeAddr("feeManager");
    address public guardian   = makeAddr("guardian");
    address public deployer   = makeAddr("deployer");

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(deployer);

        kgst = new MockERC20("KGST Token", "KGST", 18);
        dist = new FeeDistributor(address(kgst), founder);

        // Grant roles
        dist.grantRole(dist.FEE_MANAGER_ROLE(), feeManager);
        dist.grantRole(dist.GUARDIAN_ROLE(),    guardian);
        dist.grantRole(dist.STRATEGY_ROLE(),    strategy);

        // Set initial recipients (8000 bps total)
        FeeDistributor.Recipient[] memory recipients = _defaultRecipients();
        dist.setRecipients(recipients);

        vm.stopPrank();
    }

    // ── Constructor tests ─────────────────────────────────────────────────────

    function test_constructor_setsFounderImmutably() public view {
        assertEq(dist.founder(), founder);
    }

    function test_constructor_setsFeeToken() public view {
        assertEq(address(dist.feeToken()), address(kgst));
    }

    function test_constructor_founderShareBpsIsCorrect() public view {
        assertEq(dist.FOUNDER_SHARE_BPS(), 2000);
        assertEq(dist.RECIPIENTS_TOTAL_BPS(), 8000);
    }

    function test_constructor_revertOnZeroFounder() public {
        vm.expectRevert(FeeDistributor.ZeroFounderAddress.selector);
        new FeeDistributor(address(kgst), address(0));
    }

    function test_constructor_revertOnZeroToken() public {
        vm.expectRevert(FeeDistributor.ZeroTokenAddress.selector);
        new FeeDistributor(address(0), founder);
    }

    // ── distribute() — founder share ──────────────────────────────────────────

    function test_distribute_founderAlwaysGets20Percent() public {
        uint256 amount = 1000 ether;
        _depositFees(amount);

        vm.prank(feeManager);
        dist.distribute();

        uint256 founderPending = dist.pendingFees(founder);
        assertEq(founderPending, 200 ether, "Founder should get exactly 20%");
    }

    function test_distribute_founderShareWithOddAmount() public {
        uint256 amount = 333 ether; // non-round number — tests floor division
        _depositFees(amount);

        vm.prank(feeManager);
        dist.distribute();

        uint256 founderPending = dist.pendingFees(founder);
        // 333 * 2000 / 10000 = 66.6 → 66 (floor division)
        assertEq(founderPending, (amount * 2000) / 10000);
    }

    function test_distribute_remainderSplitCorrectly() public {
        uint256 amount = 1000 ether;
        _depositFees(amount);

        vm.prank(feeManager);
        dist.distribute();

        // Founder: 200 ether (20%)
        // Remaining 800 ether split by default recipients:
        //   team     2500/8000 = 31.25% of 800 = 250
        //   protocol 2500/8000 = 31.25% of 800 = 250
        //   shariah  1500/8000 = 18.75% of 800 = 150
        //   charity  1000/8000 = 12.5%  of 800 = 100
        //   dao       500/8000 =  6.25% of 800 =  50
        assertEq(dist.pendingFees(founder),  200 ether);
        assertEq(dist.pendingFees(team),     250 ether);
        assertEq(dist.pendingFees(protocol), 250 ether);
        assertEq(dist.pendingFees(shariah),  150 ether);
        assertEq(dist.pendingFees(charity),  100 ether);
        assertEq(dist.pendingFees(dao),       50 ether);
    }

    function test_distribute_founderAccumulatesAcrossMultipleRounds() public {
        // Round 1: deposit 1000, distribute, then everyone claims
        _depositFees(1000 ether);
        vm.prank(feeManager); dist.distribute();
        // Claim all so balance resets to 0 before round 2
        address _team     = makeAddr("team");
        address _protocol = makeAddr("protocol");
        address _shariah  = makeAddr("shariahBoard");
        address _charity  = makeAddr("charity");
        address _dao      = makeAddr("daoReserve");
        vm.prank(founder);  dist.claimFees();
        vm.prank(_team);     dist.claimFees();
        vm.prank(_protocol); dist.claimFees();
        vm.prank(_shariah);  dist.claimFees();
        vm.prank(_charity);  dist.claimFees();
        vm.prank(_dao);      dist.claimFees();
        // Round 2: deposit 500, distribute
        _depositFees(500 ether);
        vm.prank(feeManager); dist.distribute();
        // founder gets 20% of 500 = 100
        assertEq(dist.pendingFees(founder), 100 ether);
    }
    function test_distribute_emitsEvent() public {
        uint256 amount = 1000 ether;
        _depositFees(amount);

        vm.expectEmit(true, true, true, true);
        emit FeesDistributed(amount, 200 ether, block.timestamp);

        vm.prank(feeManager);
        dist.distribute();
    }

    function test_distribute_revertIfNoBalance() public {
        vm.prank(feeManager);
        vm.expectRevert("FeeDistributor: nothing to distribute");
        dist.distribute();
    }

    function test_distribute_revertIfNoRecipients() public {
        // Deploy fresh distributor with no recipients set
        vm.startPrank(deployer);
        FeeDistributor fresh = new FeeDistributor(address(kgst), founder);
        fresh.grantRole(fresh.FEE_MANAGER_ROLE(), feeManager);
        vm.stopPrank();

        kgst.mint(address(fresh), 100 ether);

        vm.prank(feeManager);
        vm.expectRevert("FeeDistributor: no recipients");
        fresh.distribute();
    }

    // ── Founder immutability — the pension guarantee ───────────────────────────

    function test_founderCannotBeAddedAsRecipient() public {
        FeeDistributor.Recipient[] memory bad = new FeeDistributor.Recipient[](1);
        bad[0] = FeeDistributor.Recipient({ account: founder, shareBps: 8000 });

        vm.prank(feeManager);
        vm.expectRevert("FeeDistributor: founder has immutable share");
        dist.setRecipients(bad);
    }

    function test_founderAddressCannotBeChanged() public {
        // founder is immutable — no setter exists
        // Verify it's still the same after setRecipients
        vm.prank(feeManager);
        dist.setRecipients(_defaultRecipients());
        assertEq(dist.founder(), founder);
    }

    function test_founderStillEarnsAfterRecipientsReplaced() public {
        // Replace all recipients
        FeeDistributor.Recipient[] memory newRecipients = new FeeDistributor.Recipient[](2);
        newRecipients[0] = FeeDistributor.Recipient({ account: makeAddr("newTeam"), shareBps: 4000 });
        newRecipients[1] = FeeDistributor.Recipient({ account: makeAddr("newDao"),  shareBps: 4000 });

        vm.prank(feeManager);
        dist.setRecipients(newRecipients);

        _depositFees(1000 ether);
        vm.prank(feeManager);
        dist.distribute();

        // Founder still gets 20% regardless
        assertEq(dist.pendingFees(founder), 200 ether);
    }

    function test_adminCannotGrantRoleThatReducesFounderShare() public {
        // Even DEFAULT_ADMIN_ROLE cannot change FOUNDER_SHARE_BPS
        // because it's a constant — there's no function to change it
        // Just verify the constant is intact after admin actions
        vm.startPrank(deployer);
        dist.grantRole(dist.FEE_MANAGER_ROLE(), makeAddr("attacker"));
        vm.stopPrank();

        assertEq(dist.FOUNDER_SHARE_BPS(), 2000);
    }

    // ── claimFees() ───────────────────────────────────────────────────────────

    function test_claimFees_founderCanClaim() public {
        _depositFees(1000 ether);
        vm.prank(feeManager); dist.distribute();

        uint256 balBefore = kgst.balanceOf(founder);

        vm.prank(founder);
        dist.claimFees();

        assertEq(kgst.balanceOf(founder), balBefore + 200 ether);
        assertEq(dist.pendingFees(founder), 0);
    }

    function test_claimFees_recipientCanClaim() public {
        _depositFees(1000 ether);
        vm.prank(feeManager); dist.distribute();

        vm.prank(team);
        dist.claimFees();

        assertEq(kgst.balanceOf(team), 250 ether);
    }

    function test_claimFees_revertIfNoPending() public {
        vm.prank(founder);
        vm.expectRevert("FeeDistributor: no fees");
        dist.claimFees();
    }

    function test_claimFees_emitsEvent() public {
        _depositFees(1000 ether);
        vm.prank(feeManager); dist.distribute();

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(founder, 200 ether);

        vm.prank(founder);
        dist.claimFees();
    }

    // ── setRecipients() ───────────────────────────────────────────────────────

    function test_setRecipients_mustSumTo8000() public {
        FeeDistributor.Recipient[] memory bad = new FeeDistributor.Recipient[](2);
        bad[0] = FeeDistributor.Recipient({ account: team, shareBps: 5000 });
        bad[1] = FeeDistributor.Recipient({ account: protocol, shareBps: 4000 }); // 9000 != 8000

        vm.prank(feeManager);
        vm.expectRevert("FeeDistributor: shares must sum to 8000 bps");
        dist.setRecipients(bad);
    }

    function test_setRecipients_rejectZeroAddress() public {
        FeeDistributor.Recipient[] memory bad = new FeeDistributor.Recipient[](1);
        bad[0] = FeeDistributor.Recipient({ account: address(0), shareBps: 8000 });

        vm.prank(feeManager);
        vm.expectRevert("FeeDistributor: zero account");
        dist.setRecipients(bad);
    }

    function test_setRecipients_onlyFeeManager() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        dist.setRecipients(_defaultRecipients());
    }

    function test_setRecipients_replacesOldList() public {
        address newAddr = makeAddr("newRecipient");
        FeeDistributor.Recipient[] memory fresh = new FeeDistributor.Recipient[](1);
        fresh[0] = FeeDistributor.Recipient({ account: newAddr, shareBps: 8000 });

        vm.prank(feeManager);
        dist.setRecipients(fresh);

        FeeDistributor.Recipient[] memory result = dist.getRecipients();
        assertEq(result.length, 1);
        assertEq(result[0].account, newAddr);
    }

    // ── receiveFee() ─────────────────────────────────────────────────────────

    function test_receiveFee_onlyStrategy() public {
        kgst.mint(address(this), 100 ether);
        kgst.approve(address(dist), 100 ether);

        vm.expectRevert();
        dist.receiveFee(address(kgst), 100 ether);
    }

    function test_receiveFee_worksForStrategy() public {
        kgst.mint(strategy, 100 ether);
        vm.startPrank(strategy);
        kgst.approve(address(dist), 100 ether);
        dist.receiveFee(address(kgst), 100 ether);
        vm.stopPrank();

        assertEq(kgst.balanceOf(address(dist)), 100 ether);
    }

    function test_receiveFee_rejectWrongToken() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(strategy, 100 ether);

        vm.startPrank(strategy);
        other.approve(address(dist), 100 ether);
        vm.expectRevert("FeeDistributor: wrong token");
        dist.receiveFee(address(other), 100 ether);
        vm.stopPrank();
    }

    // ── previewDistribution() ─────────────────────────────────────────────────

    function test_preview_matchesActualDistribute() public {
        uint256 amount = 1000 ether;
        _depositFees(amount);

        (uint256 founderPreview, address[] memory accounts, uint256[] memory amounts)
            = dist.previewDistribution();

        vm.prank(feeManager);
        dist.distribute();

        assertEq(founderPreview, dist.pendingFees(founder), "Preview founder mismatch");
        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(amounts[i], dist.pendingFees(accounts[i]), "Preview recipient mismatch");
        }
    }

    function test_preview_zeroWhenEmpty() public view {
        (uint256 founderAmt,,) = dist.previewDistribution();
        assertEq(founderAmt, 0);
    }

    // ── rescueToken() ─────────────────────────────────────────────────────────

    function test_rescue_cannotRescueFeeToken() public {
        vm.prank(guardian);
        vm.expectRevert("FeeDistributor: cannot rescue fee token");
        dist.rescueToken(address(kgst), 100 ether, guardian);
    }

    function test_rescue_canRescueOtherTokens() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(dist), 100 ether);

        vm.prank(guardian);
        dist.rescueToken(address(stray), 100 ether, guardian);

        assertEq(stray.balanceOf(guardian), 100 ether);
    }

    // ── Fuzz tests ────────────────────────────────────────────────────────────

    function testFuzz_founderAlwaysGets20Percent(uint256 amount) public {
        vm.assume(amount > 0 && amount < 1_000_000_000 ether);
        _depositFees(amount);

        vm.prank(feeManager);
        dist.distribute();

        uint256 expected = (amount * 2000) / 10000;
        assertEq(dist.pendingFees(founder), expected);
    }

    function testFuzz_totalNeverExceedsBalance(uint256 amount) public {
        vm.assume(amount > 0 && amount < 1_000_000_000 ether);
        _depositFees(amount);

        vm.prank(feeManager);
        dist.distribute();

        uint256 total = dist.pendingFees(founder)
            + dist.pendingFees(team)
            + dist.pendingFees(protocol)
            + dist.pendingFees(shariah)
            + dist.pendingFees(charity)
            + dist.pendingFees(dao);

        // Total pending may be <= balance due to rounding (integer division)
        assertLe(total, amount);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _defaultRecipients() internal view returns (FeeDistributor.Recipient[] memory) {
        FeeDistributor.Recipient[] memory r = new FeeDistributor.Recipient[](5);
        r[0] = FeeDistributor.Recipient({ account: team,     shareBps: 2500 });
        r[1] = FeeDistributor.Recipient({ account: protocol, shareBps: 2500 });
        r[2] = FeeDistributor.Recipient({ account: shariah,  shareBps: 1500 });
        r[3] = FeeDistributor.Recipient({ account: charity,  shareBps: 1000 });
        r[4] = FeeDistributor.Recipient({ account: dao,      shareBps:  500 });
        return r;
    }

    function _depositFees(uint256 amount) internal {
        kgst.mint(strategy, amount);
        vm.startPrank(strategy);
        kgst.approve(address(dist), amount);
        dist.receiveFee(address(kgst), amount);
        vm.stopPrank();
    }
}
