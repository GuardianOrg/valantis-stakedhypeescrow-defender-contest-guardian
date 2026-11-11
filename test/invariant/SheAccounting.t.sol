// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {SheTestBase} from "../helpers/SheTestBase.sol";
import {SheAccountingHandler} from "../helpers/SheAccountingHandler.sol";

contract SheAccountingInvariant is SheTestBase {
    SheAccountingHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new SheAccountingHandler(she, overseer, token, wrapper, distributor, manager);
        vm.deal(address(handler), 1e30);
        vm.deal(distributor, 1e30);
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.request.selector;
        selectors[4] = handler.execute.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.checkpoint.selector;
        selectors[7] = handler.emptyPool.selector;
        selectors[8] = handler.configure.selector;
        selectors[9] = handler.setPaused.selector;
        selectors[10] = handler.rejectExecution.selector;
        selectors[11] = handler.cancel.selector;
        selectors[12] = handler.rejectCancellation.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        handler.assertModel();
    }

    function invariant_independentOwnershipBucketsAndCustody() public view {
        // Foundry runs this after every handler call. Scan the full model once, including historical claims.
        handler.assertModel();
    }

    function afterInvariant() public {
        handler.emptyPool();
        handler.assertModel();
    }

    function test_referenceModelSeparatesPayersBeneficiariesAndExitOwners() public {
        handler.deposit(3, 3 ether); // Owner 0 pays; owner 1 receives the first user units.
        handler.assertModel();
        assertEq(handler.ownerUnits(0), 0);
        assertEq(handler.ownerUnits(1), 3 ether * 1e6 - SEED);
        handler.deposit(7, 2 ether); // Owner 1 pays; owner 0 receives this issuance.
        handler.assertModel();
        assertEq(handler.ownerUnits(0), 2 ether * 1e6);
        assertEq(handler.ownerUnits(1), 3 ether * 1e6 - SEED);
        handler.request(1, 10_000);
        handler.assertModel();
        handler.advance(10);
        handler.assertModel();
        handler.execute(0);
        handler.assertModel();
        assertEq(handler.paid(0), 0);
        assertEq(handler.paid(1), 3 ether - 1);
        handler.emptyPool();
        handler.assertModel();
        assertEq(handler.totalUnits(), SEED);
        assertEq(handler.requested(), 0);
    }

    function test_referenceModelCombinesDurationChangesPausesAndOwnerPayouts() public {
        handler.deposit(0, 10 ether);
        handler.assertModel();
        handler.deposit(1, 10 ether);
        handler.assertModel();
        handler.fund(4 ether);
        handler.assertModel();
        handler.advance(25);
        handler.assertModel();
        handler.configure(200, 7);
        handler.assertModel();
        handler.request(3, 4000); // Owner 0 requests under the long cooldown.
        handler.assertModel();
        handler.configure(1, 3);
        handler.assertModel();
        handler.request(4, 2000); // Owner 1 requests under the short cooldown.
        handler.assertModel();
        handler.setPaused(true);
        handler.assertModel();
        handler.advance(1);
        handler.assertModel();
        handler.rejectExecution(1, 1);
        handler.assertModel();
        handler.request(0, 5000);
        handler.assertModel();
        assertEq(handler.rejectedRequests(), 1);
        handler.deposit(2, 1 ether); // The same security pause blocks deposits and both withdrawal stages.
        handler.assertModel();
        assertEq(handler.rejectedDeposits(), 1);
        handler.donate(1 ether);
        handler.assertModel();
        handler.advance(100);
        handler.assertModel();
        handler.fund(1 ether); // Funding also works while paused, with the new three-second duration.
        handler.assertModel();
        assertEq(handler.scheduleEnd() - handler.scheduleStart(), 3);
        handler.advance(3);
        handler.assertModel();
        handler.checkpoint();
        handler.assertModel();
        handler.setPaused(false);
        handler.assertModel();
        handler.deposit(2, 1 ether);
        handler.assertModel();
        handler.rejectExecution(0, 1); // A different caller is also blocked while this request is still cooling down.
        handler.assertModel();
        handler.rejectExecution(0, 0); // The original long cooldown has not been shortened.
        handler.assertModel();
        handler.execute(1);
        handler.assertModel();
        assertEq(handler.paid(0), 0);
        assertEq(handler.paid(1), 2.1 ether);
        assertEq(handler.paid(2), 0);
        handler.rejectExecution(1, 1); // An executed request cannot be replayed.
        handler.assertModel();
        handler.advance(100);
        handler.assertModel();
        handler.rejectExecution(0, 0); // Now mature: a minimum one wei above the wstHYPE amount must fail.
        handler.assertModel();
        handler.execute(0);
        handler.assertModel();
        assertEq(handler.paid(0), 4.2 ether - 1);
        assertEq(handler.paid(1), 2.1 ether);
        assertEq(handler.rejectedExecutions(), 5);
        handler.setPaused(true);
        handler.assertModel();
        handler.emptyPool(); // Cleanup explicitly unpauses and waits for all snapshotted maturities.
        handler.assertModel();
        assertEq(handler.requested(), 0);
        assertEq(handler.totalUnits(), SEED);
        for (uint256 i; i < 11; ++i) {
            assertGt(handler.actions(i), 0);
        }
    }

    function test_referenceModelCancelsRepricesAndRerequestsWithoutReusingMaturity() public {
        handler.deposit(0, 10 ether);
        handler.assertModel();
        handler.deposit(1, 10 ether);
        handler.assertModel();
        handler.request(0, 4000);
        handler.assertModel();
        handler.request(1, 2000);
        handler.assertModel();
        handler.fund(4 ether);
        handler.assertModel();
        handler.advance(25);
        handler.assertModel();
        handler.donate(2 ether);
        handler.assertModel();
        handler.cancel(0);
        handler.assertModel();
        assertEq(handler.cancelledRequests(), 1);
        assertEq(handler.requested(), 2 ether * 1e6);
        assertEq(uint256(she.getWithdrawalRequest(1).status), 3);
        handler.rejectExecution(0, 0);
        handler.assertModel();
        handler.rejectCancellation(0, 0);
        handler.assertModel();
        handler.setPaused(true);
        handler.assertModel();
        handler.rejectCancellation(1, 1);
        handler.assertModel();
        handler.setPaused(false);
        handler.assertModel();
        handler.advance(100);
        handler.assertModel();
        handler.cancel(1); // Already matured: cancellation still returns to active ownership.
        handler.assertModel();
        assertEq(handler.requested(), 0);
        assertEq(handler.cancelledRequests(), 2);
        assertEq(handler.rejectedCancellations(), 2);
        handler.configure(20, 100);
        handler.assertModel();
        handler.request(0, 10_000);
        handler.assertModel();
        assertEq(she.getWithdrawalRequest(3).eligibleAt, block.timestamp + 20);
        handler.rejectExecution(2, 0);
        handler.assertModel();
        handler.advance(20);
        handler.assertModel();
        handler.execute(2);
        handler.assertModel();
        handler.emptyPool();
        handler.assertModel();
        assertEq(handler.totalUnits(), SEED);
        assertEq(handler.requested(), 0);
        assertGt(handler.actions(11), 0);
        assertGt(handler.actions(12), 0);
    }

    function test_referenceModelEmptyRefillAndFractionalStreamSequence() public {
        // Direct calls do not trigger Foundry's invariant hook, so check every intermediate state explicitly.
        handler.donate(1);
        handler.assertModel();
        handler.fund(7);
        handler.assertModel();
        assertEq(handler.rejectedUnseededFunding(), 1);
        handler.checkpoint();
        handler.assertModel();
        assertEq(handler.rejectedUnseededCheckpoints(), 1);
        handler.deposit(0, 3 ether);
        handler.assertModel();
        handler.emptyPool();
        handler.assertModel();
        handler.fund(7);
        handler.assertModel();
        handler.advance(25);
        handler.assertModel();
        handler.deposit(0, 3 ether);
        handler.assertModel();
        handler.deposit(1, 7 ether);
        handler.assertModel();
        handler.advance(17);
        handler.assertModel();
        handler.request(0, 4000);
        handler.assertModel();
        handler.donate(11);
        handler.assertModel();
        handler.advance(10);
        handler.assertModel();
        handler.execute(1); // Claim zero was resolved when establishing the seed-only pool above.
        handler.assertModel();
        handler.checkpoint();
        handler.assertModel();
        handler.emptyPool();
        handler.assertModel();
        assertEq(handler.totalUnits(), SEED);
        assertEq(handler.requested(), 0);
        handler.advance(150);
        handler.assertModel();
        handler.checkpoint();
        handler.assertModel();
        uint256 retained = handler.reserve();
        assertGt(retained, 0);
        uint256 seedAssets = handler.active();
        handler.deposit(2, 2 ether);
        handler.assertModel();
        // The seed retains its old entitlement; entry pays only the transferable charge for issued units.
        uint256 issued = uint256(2 ether * 1e6) * SEED / seedAssets;
        uint256 charge = (issued * seedAssets + SEED * 1e6 - 1) / (SEED * 1e6);
        assertEq(handler.active(), seedAssets + charge * 1e6);
        assertEq(handler.reserve(), retained);
        handler.fund(13);
        handler.assertModel();
        handler.advance(100);
        handler.assertModel();
        handler.checkpoint();
        handler.assertModel();
        assertEq(handler.active(), seedAssets + charge * 1e6 + retained + 13 * 1e6);
        handler.emptyPool();
        handler.assertModel();
        for (uint256 i; i < 8; ++i) {
            assertGt(handler.actions(i), 0);
        }
    }
}
