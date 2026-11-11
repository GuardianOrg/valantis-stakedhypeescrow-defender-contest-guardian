// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract SheConfigurationTest is SheAssertions {
    function setUp() public override {
        super.setUp();
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether); // Leave both emissions and surplus uncheckpointed.
    }

    function test_durationSettersRequireCurrentDefaultAdmin() public {
        address[4] memory callers = [alice, manager, distributor, upgradeGov];
        for (uint256 i; i < callers.length; ++i) {
            rejectSetters(callers[i]);
        }
        she.beginDefaultAdminTransfer(bob);
        rejectSetters(bob); // Pending administration does not authorize a setter.
        (, uint48 schedule) = she.pendingDefaultAdmin();
        vm.warp(uint256(schedule) + 1);
        vm.prank(bob);
        she.acceptDefaultAdminTransfer();
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(she.hasRole(she.DEFAULT_ADMIN_ROLE(), bob));
        rejectSetters(address(this));
        bytes32 before = snapshotWithoutConfiguration();
        vm.prank(bob);
        she.setCooldown(20);
        vm.prank(bob);
        she.setRewardDuration(200);
        assertConfiguration(20, 200);
        assertEq(snapshotWithoutConfiguration(), before);
    }

    function rejectSetters(address caller) private {
        bytes memory reason =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0));
        reject(caller, 0, abi.encodeCall(I.setCooldown, (20)), reason);
        reject(caller, 0, abi.encodeCall(I.setRewardDuration, (200)), reason);
    }

    function test_invalidDurationUpdatesPreserveFullState() public {
        uint64[3] memory cooldowns = [uint64(0), uint64(180 days + 1), type(uint64).max];
        uint64[3] memory durations = [uint64(0), uint64(7 days + 1), type(uint64).max];
        bytes memory reason = abi.encodeWithSelector(I.StakedHypeEscrow__InvalidConfiguration.selector);
        for (uint256 i; i < cooldowns.length; ++i) {
            reject(address(this), 0, abi.encodeCall(I.setCooldown, (cooldowns[i])), reason);
            reject(address(this), 0, abi.encodeCall(I.setRewardDuration, (durations[i])), reason);
        }
        assertConfiguration(10, 100);
    }

    function test_durationBoundsAndEventsPreserveAllOtherState() public {
        assertEq(she.MAX_REWARD_DURATION(), 7 days);
        bytes32 before = snapshotWithoutConfiguration();
        uint64[3] memory cooldowns = [uint64(1), uint64(180 days), uint64(180 days)];
        uint64[3] memory durations = [uint64(1), uint64(7 days), uint64(7 days)];
        for (uint256 i; i < cooldowns.length; ++i) {
            uint64 oldRewardDuration = she.configuration().rewardDuration;
            vm.expectEmit(address(she));
            emit I.CooldownSet(cooldowns[i]);
            she.setCooldown(cooldowns[i]);
            assertConfiguration(cooldowns[i], oldRewardDuration);
            assertEq(snapshotWithoutConfiguration(), before);
            vm.expectEmit(address(she));
            emit I.RewardDurationSet(durations[i]);
            she.setRewardDuration(durations[i]);
            assertConfiguration(cooldowns[i], durations[i]);
            assertEq(snapshotWithoutConfiguration(), before);
        }
    }

    function test_cooldownUpdatesOnlyAffectNewRequestsFromExistingDeposits() public {
        I.WithdrawalRequest memory matured = she.getWithdrawalRequest(1);
        uint256 coolingId = request(alice, 1 ether * 1e6);
        I.WithdrawalRequest memory cooling = she.getWithdrawalRequest(coolingId);
        assertGt(cooling.eligibleAt, block.timestamp);
        assertLe(matured.eligibleAt, block.timestamp);
        she.setCooldown(180 days);
        uint256 longId = request(alice, 1 ether * 1e6);
        I.WithdrawalRequest memory longRequest = she.getWithdrawalRequest(longId);
        assertEq(longRequest.eligibleAt, block.timestamp + 180 days);
        she.setCooldown(1);
        uint256 shortId = request(alice, 1 ether * 1e6);
        assertEq(she.getWithdrawalRequest(shortId).eligibleAt, block.timestamp + 1);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), abi.encode(matured));
        assertEq(abi.encode(she.getWithdrawalRequest(coolingId)), abi.encode(cooling));
        assertEq(abi.encode(she.getWithdrawalRequest(longId)), abi.encode(longRequest));
        executeAndAssertPayout(alice, 1, token.sharesToBalance(matured.rawShares));
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (longId, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        executeAndAssertPayout(alice, shortId, token.sharesToBalance(she.getWithdrawalRequest(shortId).rawShares));
        executeAndAssertPayout(alice, coolingId, token.sharesToBalance(cooling.rawShares));
        assertEq(abi.encode(she.getWithdrawalRequest(longId)), abi.encode(longRequest));
    }

    function test_rewardDurationUpdatesPreserveCurrentStreamAndApplyAtNextFunding() public {
        (I.RewardStream memory original,) = she.rewardState();
        bytes32 before = snapshotWithoutConfiguration();
        she.setRewardDuration(1);
        assertEq(snapshotWithoutConfiguration(), before);
        reject(
            distributor,
            1 ether,
            abi.encodeCall(I.fundRewards, (0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__StreamActive.selector)
        );
        vm.warp(original.start + 50);
        she.checkpointRewards();
        (I.RewardStream memory halfway,) = she.rewardState();
        assertEq(halfway.start, original.start);
        assertEq(halfway.end, original.end);
        assertEq(halfway.totalRawShares, original.totalRawShares);
        assertEq(halfway.releasedRawShares, 2 ether * 1e6);
        assertEq(storedAccounting().rewardRawShares, 2 ether * 1e6);
        assertEq(storedAccounting().activeRawShares, 21 ether * 1e6);
        vm.warp(original.end);
        fund(1 ether);
        (I.RewardStream memory shortStream,) = she.rewardState();
        assertEq(shortStream.start, original.end);
        assertEq(shortStream.end, original.end + 1);
        assertEq(shortStream.totalRawShares, 1 ether * 1e6);
        assertEq(shortStream.releasedRawShares, 0);
        assertEq(storedAccounting().activeRawShares, 23 ether * 1e6);
        she.setRewardDuration(7 days);
        vm.warp(shortStream.end);
        she.checkpointRewards();
        assertEq(storedAccounting().activeRawShares, 24 ether * 1e6);
        assertEq(storedAccounting().rewardRawShares, 0);
        fund(1 ether);
        (I.RewardStream memory longStream,) = she.rewardState();
        assertEq(longStream.start, shortStream.end);
        assertEq(longStream.end, shortStream.end + 7 days);
        assertEq(longStream.totalRawShares, 1 ether * 1e6);
        assertEq(longStream.releasedRawShares, 0);
        assertEq(storedAccounting().activeRawShares, 24 ether * 1e6);
        assertEq(storedAccounting().rewardRawShares, 1 ether * 1e6);
    }

    function test_newDurationReschedulesSeedOnlyReservesWithoutChangingRequests() public {
        (uint256 aliceUnits,,) = she.account(alice);
        request(alice, aliceUnits);
        (uint256 bobUnits,,) = she.account(bob);
        request(bob, bobUnits);
        assertEq(she.totalAccounting().totalOwnershipUnits, SEED);
        uint256 seedAssets = storedAccounting().activeRawShares;
        uint256 requested = storedAccounting().requestedRawShares;
        donate(1 ether);
        she.setRewardDuration(1);
        (I.RewardStream memory current,) = she.rewardState();
        vm.warp(current.end);
        she.checkpointRewards();
        uint256 retained;
        (current, retained) = she.rewardState();
        assertEq(retained, 4 ether * 1e6); // Three retained stream tokens plus one seed-only donation.
        assertEq(current.releasedRawShares, 4 ether * 1e6);
        assertEq(storedAccounting().activeRawShares, seedAssets);
        fund(1 ether);
        (I.RewardStream memory next,) = she.rewardState();
        assertEq(next.totalRawShares, 5 ether * 1e6);
        assertEq(next.end, next.start + 1);
        deposit(bob, 1 ether);
        vm.warp(next.end);
        she.checkpointRewards();
        assertEq(storedAccounting().activeRawShares, seedAssets + 6 ether * 1e6);
        assertEq(storedAccounting().rewardRawShares, 0);
        assertEq(storedAccounting().requestedRawShares, requested);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.REQUESTED));
        }
    }

    function test_durationSettersWorkWhilePausedWithoutResumingWithdrawals() public {
        vm.prank(manager);
        she.setPaused(true);
        bytes32 before = snapshotWithoutConfiguration();
        she.setCooldown(1);
        she.setRewardDuration(1);
        assertConfiguration(1, 1);
        assertEq(snapshotWithoutConfiguration(), before);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (1, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector)
        );
    }

    function assertConfiguration(uint64 cooldown, uint64 rewardDuration) private view {
        assertEq(
            abi.encode(she.configuration()),
            abi.encode(I.Configuration(address(token), address(wrapper), address(overseer), cooldown, rewardDuration))
        );
    }
}
