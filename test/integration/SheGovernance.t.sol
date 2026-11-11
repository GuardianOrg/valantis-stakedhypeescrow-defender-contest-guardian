// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules as AdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

contract SheGovernanceTest is SheAssertions {
    function setUp() public override {
        super.setUp();
        deposit(alice, 10 ether);
        request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether); // Governance must not checkpoint either pending emissions or surplus.
    }

    function test_adminTransferRequiresStrictlyPassedScheduleAndExplicitAcceptance() public {
        bytes32 economicBefore = economicState();
        uint48 schedule = uint48(block.timestamp + 20);
        vm.expectEmit(address(she));
        emit AdminRules.DefaultAdminTransferScheduled(bob, schedule);
        she.beginDefaultAdminTransfer(bob);
        assertPendingAdmin(bob, schedule);
        assertEq(she.owner(), address(this));
        for (uint256 i; i < 2; ++i) {
            vm.warp(uint256(schedule) - 1 + i);
            reject(
                bob,
                0,
                abi.encodeCall(AdminRules.acceptDefaultAdminTransfer, ()),
                abi.encodeWithSelector(AdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule)
            );
            assertEq(she.defaultAdmin(), address(this));
            assertFalse(she.hasRole(bytes32(0), bob));
        }
        vm.warp(uint256(schedule) + 1);
        reject(
            alice,
            0,
            abi.encodeCall(AdminRules.acceptDefaultAdminTransfer, ()),
            abi.encodeWithSelector(AdminRules.AccessControlInvalidDefaultAdmin.selector, alice)
        );
        vm.prank(bob);
        she.acceptDefaultAdminTransfer();
        assertEq(she.defaultAdmin(), bob);
        assertEq(she.owner(), bob);
        assertPendingAdmin(address(0), 0);
        assertTrue(she.hasRole(bytes32(0), bob));
        assertFalse(she.hasRole(bytes32(0), address(this)));
        assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
        assertTrue(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        assertEq(economicState(), economicBefore);
        reject(
            address(this), 0, abi.encodeCall(AdminRules.beginDefaultAdminTransfer, (alice)), unauthorized(address(this))
        );
    }

    function test_cancelTransferAndUnauthorizedGovernancePreserveState() public {
        bytes32 economicBefore = economicState();
        she.beginDefaultAdminTransfer(bob);
        (, uint48 schedule) = she.pendingDefaultAdmin();
        address[4] memory callers = [alice, manager, distributor, upgradeGov];
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];
            reject(caller, 0, abi.encodeCall(AdminRules.beginDefaultAdminTransfer, (caller)), unauthorized(caller));
            reject(caller, 0, abi.encodeCall(AdminRules.cancelDefaultAdminTransfer, ()), unauthorized(caller));
            reject(caller, 0, abi.encodeCall(AdminRules.changeDefaultAdminDelay, (uint48(0))), unauthorized(caller));
            reject(caller, 0, abi.encodeCall(AdminRules.rollbackDefaultAdminDelay, ()), unauthorized(caller));
        }
        vm.expectEmit(address(she));
        emit AdminRules.DefaultAdminTransferCanceled();
        she.cancelDefaultAdminTransfer();
        assertPendingAdmin(address(0), 0);
        vm.warp(uint256(schedule) + 1);
        reject(
            bob,
            0,
            abi.encodeCall(AdminRules.acceptDefaultAdminTransfer, ()),
            abi.encodeWithSelector(AdminRules.AccessControlInvalidDefaultAdmin.selector, bob)
        );
        she.beginDefaultAdminTransfer(alice);
        assertPendingAdmin(alice, uint48(block.timestamp + 20));
        assertEq(she.defaultAdmin(), address(this));
        assertEq(economicState(), economicBefore);
    }

    function test_delayChangesUseStrictBoundaryAndPreserveExistingTransferSchedule() public {
        uint48[4] memory delays = [uint48(0), uint48(7), uint48(40), uint48(10 days)];
        uint48[4] memory waits = [uint48(20), uint48(13), uint48(40), uint48(5 days)];
        for (uint256 i; i < delays.length; ++i) {
            uint256 branch = vm.snapshot();
            bytes32 economicBefore = economicState();
            she.beginDefaultAdminTransfer(bob);
            (, uint48 transferSchedule) = she.pendingDefaultAdmin();
            uint48 schedule = uint48(block.timestamp) + waits[i];
            vm.expectEmit(address(she));
            emit AdminRules.DefaultAdminDelayChangeScheduled(delays[i], schedule);
            she.changeDefaultAdminDelay(delays[i]);
            for (uint256 j; j < 2; ++j) {
                vm.warp(uint256(schedule) - 1 + j);
                assertEq(she.defaultAdminDelay(), 20);
                assertPendingDelay(delays[i], schedule);
                assertPendingAdmin(bob, transferSchedule);
            }
            vm.warp(uint256(schedule) + 1);
            assertEq(she.defaultAdminDelay(), delays[i]);
            assertPendingDelay(0, 0);
            assertPendingAdmin(bob, transferSchedule);
            she.rollbackDefaultAdminDelay(); // An effective change cannot be undone by rollback.
            assertEq(she.defaultAdminDelay(), delays[i]);
            she.beginDefaultAdminTransfer(alice);
            assertPendingAdmin(alice, uint48(block.timestamp) + delays[i]);
            assertEq(economicState(), economicBefore);
            assertTrue(vm.revertTo(branch));
        }
    }

    function test_delayRollbackBeforeOrAtScheduleCancelsChange() public {
        for (uint256 i; i < 2; ++i) {
            uint256 branch = vm.snapshot();
            bytes32 economicBefore = economicState();
            she.changeDefaultAdminDelay(40);
            (, uint48 schedule) = she.pendingDefaultAdminDelay();
            assertEq(schedule, block.timestamp + 40);
            vm.warp(uint256(schedule) - 1 + i);
            vm.expectEmit(address(she));
            emit AdminRules.DefaultAdminDelayChangeCanceled();
            she.rollbackDefaultAdminDelay();
            assertPendingDelay(0, 0);
            vm.warp(uint256(schedule) + 1);
            assertEq(she.defaultAdminDelay(), 20);
            she.beginDefaultAdminTransfer(bob);
            assertPendingAdmin(bob, uint48(block.timestamp + 20));
            assertEq(economicState(), economicBefore);
            assertTrue(vm.revertTo(branch));
        }
    }

    function test_defaultAdminRenunciationRequiresDelayedZeroAddressTransfer() public {
        bytes32 economicBefore = economicState();
        bytes memory action = abi.encodeCall(IAccessControl.renounceRole, (bytes32(0), address(this)));
        reject(
            address(this),
            0,
            action,
            abi.encodeWithSelector(AdminRules.AccessControlEnforcedDefaultAdminDelay.selector, uint48(0))
        );
        she.beginDefaultAdminTransfer(address(0));
        (, uint48 schedule) = she.pendingDefaultAdmin();
        assertEq(schedule, block.timestamp + 20);
        for (uint256 i; i < 2; ++i) {
            vm.warp(uint256(schedule) - 1 + i);
            reject(
                address(this),
                0,
                action,
                abi.encodeWithSelector(AdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule)
            );
        }
        vm.warp(uint256(schedule) + 1);
        reject(bob, 0, action, abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        she.renounceRole(bytes32(0), address(this));
        assertEq(she.defaultAdmin(), address(0));
        assertEq(she.owner(), address(0));
        assertPendingAdmin(address(0), 0);
        assertFalse(she.hasRole(bytes32(0), address(this)));
        assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
        assertTrue(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        assertEq(economicState(), economicBefore);
        reject(address(this), 0, abi.encodeCall(I.setCooldown, (uint64(1))), unauthorized(address(this)));
        reject(
            address(this),
            0,
            abi.encodeCall(IAccessControl.grantRole, (bytes32(0), address(this))),
            abi.encodeWithSelector(AdminRules.AccessControlEnforcedDefaultAdminRules.selector)
        );
    }

    function unauthorized(address caller) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0));
    }

    function assertPendingAdmin(address expected, uint48 timestamp) private view {
        (address pending, uint48 schedule) = she.pendingDefaultAdmin();
        assertEq(pending, expected);
        assertEq(schedule, timestamp);
    }

    function assertPendingDelay(uint48 expected, uint48 timestamp) private view {
        (uint48 pending, uint48 schedule) = she.pendingDefaultAdminDelay();
        assertEq(pending, expected);
        assertEq(schedule, timestamp);
    }

    function economicState() private view returns (bytes32 digest) {
        for (uint256 i; i < 15; ++i) {
            digest = keccak256(abi.encode(digest, vm.load(address(she), bytes32(SHE_SLOT + i))));
        }
        (uint256 units,,) = she.account(alice);
        return keccak256(
            abi.encode(
                digest,
                units,
                she.getWithdrawalRequest(1),
                token.sharesOf(address(she)),
                token.totalShares(),
                token.totalSupply(),
                address(she).balance,
                address(overseer).balance,
                overseer.getAllBurns(),
                she.isLocked()
            )
        );
    }
}
