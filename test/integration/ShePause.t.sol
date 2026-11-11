// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ShePauseTest is SheAssertions {
    function setPauseAndAssert(address caller, bool value) private {
        bytes32 beforeState = snapshotWithoutPause();
        vm.expectEmit(false, false, false, true, address(she));
        emit I.PausedSet(value);
        vm.prank(caller);
        she.setPaused(value);
        assertEq(she.paused(), value);
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 11))), value ? 1 : 0);
        assertEq(snapshotWithoutPause(), beforeState, "pause changed unrelated persistent state");
    }

    function rejectPause(address caller, bool value) private {
        reject(
            caller,
            0,
            abi.encodeCall(I.setPaused, (value)),
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, she.MANAGER_ROLE())
        );
    }

    function test_managerAndDefaultAdminCanPauseAndResumeEachOther() public {
        request(alice, deposit(alice, 10 ether) / 2);
        deposit(bob, 5 ether);
        fund(1 ether);
        vm.warp(block.timestamp + 5);
        donate(1 ether);
        assertFalse(she.paused());
        assertFalse(she.hasRole(she.MANAGER_ROLE(), address(this)));
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), manager));

        setPauseAndAssert(manager, true);
        setPauseAndAssert(address(this), false);
        setPauseAndAssert(address(this), true);
        setPauseAndAssert(manager, false);
        // Repeated calls preserve the same state and still emit the selected global state.
        setPauseAndAssert(manager, false);
        setPauseAndAssert(address(this), true);
        setPauseAndAssert(manager, true);
        setPauseAndAssert(address(this), false);
        backed();
    }

    function test_pausePermissionFollowsCurrentRolesAndAdminTransfer() public {
        request(alice, deposit(alice, 10 ether));
        address[4] memory unauthorized = [alice, bob, distributor, upgradeGov];
        for (uint256 i; i < unauthorized.length; ++i) {
            rejectPause(unauthorized[i], true);
        }
        setPauseAndAssert(manager, true);
        for (uint256 i; i < unauthorized.length; ++i) {
            rejectPause(unauthorized[i], false);
        }

        she.revokeRole(she.MANAGER_ROLE(), manager);
        rejectPause(manager, false);
        setPauseAndAssert(address(this), false);
        rejectPause(manager, true);
        she.grantRole(she.MANAGER_ROLE(), address(this));
        she.revokeRole(she.MANAGER_ROLE(), address(this));
        setPauseAndAssert(address(this), true); // The independent default-admin authority remains valid.

        she.beginDefaultAdminTransfer(bob);
        (, uint48 schedule) = she.pendingDefaultAdmin();
        rejectPause(bob, false);
        vm.warp(uint256(schedule) + 1);
        rejectPause(bob, false); // The scheduled transfer must also be accepted.
        vm.prank(bob);
        she.acceptDefaultAdminTransfer();
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(she.hasRole(she.MANAGER_ROLE(), bob));
        rejectPause(address(this), false);
        setPauseAndAssert(bob, false);
        rejectPause(address(this), true);

        vm.startPrank(bob);
        she.grantRole(she.MANAGER_ROLE(), address(this));
        vm.stopPrank();
        setPauseAndAssert(address(this), true); // A former admin can still act if separately granted manager.
        setPauseAndAssert(bob, false);
        vm.startPrank(bob);
        she.revokeRole(she.MANAGER_ROLE(), address(this));
        vm.stopPrank();
        rejectPause(address(this), true);
        backed();
    }

    function test_globalPauseRejectsAllUserAssetOperationsWithFullRollbackAndPreservesClocks() public {
        uint256 aliceUnits = deposit(alice, 10 ether);
        uint256 aliceId = request(alice, aliceUnits / 2);
        vm.warp(block.timestamp + 5);
        uint256 bobUnits = deposit(bob, 10 ether);
        uint256 bobId = request(bob, bobUnits / 2);
        I.WithdrawalRequest memory aliceRequest = she.getWithdrawalRequest(aliceId);
        I.WithdrawalRequest memory bobRequest = she.getWithdrawalRequest(bobId);
        overseer.mint{value: 2 ether}(alice);
        vm.prank(alice);
        wrapper.approve(address(she), 2 ether);
        fund(1 ether);
        vm.warp(aliceRequest.eligibleAt);
        donate(1 ether); // A blocked operation must not persist a reward or surplus checkpoint.
        setPauseAndAssert(manager, true);
        bytes memory reason = abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector);

        vm.mockCallRevert(
            address(wrapper), abi.encodeWithSelector(IERC20.transferFrom.selector), bytes("unexpected transferFrom")
        );
        reject(alice, 0, abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)), reason);
        vm.mockCallRevert(
            address(wrapper), abi.encodeWithSelector(IERC20.transfer.selector), bytes("unexpected transfer")
        );
        reject(alice, 0, abi.encodeCall(I.executeWithdrawal, (aliceId, 0)), reason); // Already mature.
        reject(bob, 0, abi.encodeCall(I.executeWithdrawal, (bobId, 0)), reason); // Still cooling down.
        reject(alice, 0, abi.encodeCall(I.requestWithdrawal, (aliceUnits / 2, 0)), reason);
        (bool aliceEligible, uint256 aliceAmount) = lens.previewExecution(I(address(she)), aliceId);
        (bool bobEligible, uint256 bobAmount) = lens.previewExecution(I(address(she)), bobId);
        assertFalse(aliceEligible);
        assertFalse(bobEligible);
        assertEq(aliceAmount, aliceRequest.rawShares / 1e6);
        assertEq(bobAmount, bobRequest.rawShares / 1e6);

        vm.warp(bobRequest.eligibleAt + 100);
        setPauseAndAssert(address(this), true);
        reject(bob, 0, abi.encodeCall(I.executeWithdrawal, (bobId, 0)), reason);
        vm.clearMockedCalls();
        setPauseAndAssert(address(this), false);
        assertEq(abi.encode(she.getWithdrawalRequest(aliceId)), abi.encode(aliceRequest));
        assertEq(abi.encode(she.getWithdrawalRequest(bobId)), abi.encode(bobRequest));
        (aliceEligible,) = lens.previewExecution(I(address(she)), aliceId);
        (bobEligible,) = lens.previewExecution(I(address(she)), bobId);
        assertTrue(aliceEligible);
        assertTrue(bobEligible);
        executeAndAssertPayout(bob, bobId, bobAmount);
        executeAndAssertPayout(alice, aliceId, aliceAmount);
        depositAndRequestAfterResume(bobId);
    }

    function depositAndRequestAfterResume(uint256 previousId) private {
        uint256 sharesBefore = token.sharesOf(address(she));
        uint256 aliceSharesBefore = token.sharesOf(alice);
        (uint256 bobUnitsBefore,,) = she.account(bob);
        vm.prank(alice);
        (uint256 issued, uint256 accepted) = she.deposit(1 ether, bob, 1, 1 ether);
        assertGt(issued, 0);
        assertEq(accepted, 1 ether);
        assertEq(token.sharesOf(address(she)), sharesBefore + 1 ether * 1e6);
        assertEq(token.sharesOf(alice), aliceSharesBefore - 1 ether * 1e6);
        assertEq(wrapper.allowance(alice, address(she)), 1 ether);
        (uint256 bobUnitsAfter,,) = she.account(bob);
        assertEq(bobUnitsAfter, bobUnitsBefore + issued);
        uint256 nextId = request(bob, issued);
        assertEq(nextId, previousId + 1);
        assertEq(she.getWithdrawalRequest(nextId).requestedAt, block.timestamp);
        assertEq(she.getWithdrawalRequest(nextId).eligibleAt, block.timestamp + 10);
        backed();
    }

    function test_pauseAlsoBlocksFirstDepositWithoutIssuingSeed() public {
        overseer.mint{value: 1 ether}(alice);
        vm.prank(alice);
        wrapper.approve(address(she), 1 ether);
        setPauseAndAssert(address(this), true);
        reject(
            alice,
            0,
            abi.encodeCall(I.deposit, (1 ether, alice, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector)
        );
        assertEq(she.totalAccounting().totalOwnershipUnits, 0);
        assertEq(token.sharesOf(address(she)), 0);
        // Operational roles cannot bypass the global guard on user asset operations.
        reject(
            manager,
            0,
            abi.encodeCall(I.deposit, (1 ether, alice, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector)
        );
        reject(
            address(this),
            0,
            abi.encodeCall(I.deposit, (1 ether, alice, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector)
        );
        setPauseAndAssert(manager, false);
        vm.prank(alice);
        (uint256 units, uint256 accepted) = she.deposit(1 ether, alice, 1 ether * 1e6 - SEED, 1 ether);
        assertEq(units, 1 ether * 1e6 - SEED);
        assertEq(accepted, 1 ether);
        (uint256 seedUnits,,) = she.account(address(1));
        assertEq(seedUnits, SEED);
        assertEq(she.totalAccounting().totalOwnershipUnits, 1 ether * 1e6);
        assertEq(token.sharesOf(address(she)), 1 ether * 1e6);
        assertEq(wrapper.balanceOf(alice), 0);
        assertEq(wrapper.allowance(alice, address(she)), 0);
        backed();
    }
}
