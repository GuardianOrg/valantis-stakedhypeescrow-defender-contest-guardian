// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Replays SHE logs without consulting SHE state; reads are used only to validate the reconstructed result.
contract SheEventsTest is SheAssertions {
    uint256 private constant G = 1e6;
    I.Accounting private indexedPool;
    I.RewardStream private indexedStream;
    mapping(address => uint256) private indexedUnits;
    mapping(address => uint256) private indexedPending;
    mapping(uint256 => I.WithdrawalRequest) private indexedRequests;
    mapping(bytes32 => uint256) private eventCount;

    function test_replayDonationsBeforeFirstDepositAndFundingAfterBootstrap() public {
        donate(5 ether);
        vm.warp(1050);
        vm.recordLogs();
        deposit(alice, 2 ether);
        replay();
        assertEq(indexedPool.activeRawShares, 2 ether * G);
        assertEq(indexedPool.rewardRawShares, 5 ether * G);
        assertEq(abi.encode(indexedStream), abi.encode(I.RewardStream(0, 0, 0, 0)));
        assertEq(indexedUnits[alice], 2 ether * G - SEED);
        vm.recordLogs();
        fund(1 ether);
        replay();
        assertEq(indexedStream.totalRawShares, 6 ether * G);
        assertEq(indexedStream.start, 1050);
        assertEq(indexedStream.end, 1150);
        vm.warp(1100);
        assertReplay();
        assertEq(effectivePool().activeRawShares, 5 ether * G);
        assertEq(effectivePool().rewardRawShares, 3 ether * G);
    }

    function test_replayMultipleOwnersStreamingCancellationAndThirdPartyExecution() public {
        // The payer does not receive the beneficiary's external reward weight.
        overseer.mint{value: 10 ether}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 10 ether);
        vm.recordLogs();
        vm.prank(bob);
        she.deposit(10 ether, alice, 0, 0);
        replay();
        assertEq(indexedUnits[bob], 0);
        assertEq(indexedUnits[alice], 10 ether * G - SEED);
        assertEq(indexedUnits[address(1)], SEED);
        assertEq(indexedPool.totalOwnershipUnits, 10 ether * G);
        assertEq(eventCount[I.SeedLocked.selector], 1);

        vm.recordLogs();
        deposit(bob, 10 ether);
        fund(4 ether);
        replay();
        vm.warp(1025);
        assertReplay(); // Holdings grow even though no checkpoint transaction has occurred.
        assertEq(effectivePool().activeRawShares, 21 ether * G);
        vm.recordLogs();
        uint256 id = request(alice, 4 ether * G);
        replay();
        assertEq(indexedRequests[id].rawShares, 4.2 ether * G);
        assertEq(indexedPool.activeRawShares, 16.8 ether * G);
        assertEq(indexedPool.totalOwnershipUnits, 16 ether * G);
        assertEq(indexedPending[alice], 4.2 ether * G);

        vm.warp(1050);
        donate(2 ether);
        vm.recordLogs();
        vm.prank(alice);
        she.cancelWithdrawal(id, 0);
        replay();
        // A before return = 19.8; returning 4.2 shares buys floor(4.2 * 16 / 19.8) units.
        uint256 returnedUnits = (4.2 ether * G) * (16 ether * G) / (19.8 ether * G);
        assertEq(indexedUnits[alice], 6 ether * G - SEED + returnedUnits);
        assertEq(indexedPool.activeRawShares, 24 ether * G);
        assertEq(indexedPending[alice], 0);
        assertEq(uint256(indexedRequests[id].status), uint256(I.RequestStatus.CANCELLED));

        vm.recordLogs();
        uint256 first = request(alice, indexedUnits[alice] / 2);
        uint256 second = request(alice, indexedUnits[alice] / 4);
        replay();
        vm.warp(1060);
        vm.recordLogs();
        vm.prank(manager); // The owner still has active units and another pending request.
        she.executeWithdrawal(first, 0);
        replay();
        assertEq(indexedPending[alice], indexedRequests[second].rawShares);
        assertEq(indexedUnits[manager], 0);
        assertEq(token.sharesOf(manager), 0);
        assertEq(eventCount[I.Deposited.selector], 2);
        assertEq(eventCount[I.WithdrawalRequested.selector], 3);
        assertEq(eventCount[I.WithdrawalCancelled.selector], 1);
        assertEq(eventCount[I.WithdrawalExecuted.selector], 1);
        assertEq(eventCount[I.RewardsFunded.selector], 1);
        assertEq(eventCount[I.RewardsCheckpointed.selector], 3);
    }

    function test_replaySeedOnlyRetentionDustRefillAndPausedCheckpoints() public {
        vm.recordLogs();
        deposit(alice, 2);
        fund(1);
        replay();
        vm.warp(1050);
        vm.recordLogs();
        uint256 id = request(alice, indexedUnits[alice]);
        replay();
        assertEq(indexedPool.activeRawShares, 1250);
        assertEq(indexedPool.totalOwnershipUnits, SEED);
        assertEq(indexedRequests[id].rawShares, 2_498_750);

        vm.warp(1060);
        donate(1);
        vm.recordLogs();
        vm.prank(bob);
        she.executeWithdrawal(id, 2);
        replay();
        assertEq(indexedPool.activeRawShares, 1250);
        assertEq(indexedPool.rewardRawShares, 1_998_750);
        assertEq(indexedPending[alice], 0);
        assertEq(indexedUnits[alice], 0);

        vm.prank(manager);
        she.setPaused(true);
        vm.warp(1100);
        assertReplay(); // Empty-period release remains in reserve, not allocated to the seed.
        vm.recordLogs();
        she.checkpointRewards();
        replay();
        assertEq(indexedStream.releasedRawShares, G);
        assertEq(indexedPool.rewardRawShares, 1_998_750);
        she.setPaused(false);
        vm.recordLogs();
        deposit(bob, 1);
        fund(1);
        replay();
        assertEq(eventCount[I.SeedLocked.selector], 1);
        assertEq(indexedUnits[bob], 800_000);
        assertEq(indexedStream.totalRawShares, 2_998_750);
        vm.warp(1200);
        assertReplay();
        vm.recordLogs();
        she.checkpointRewards();
        replay();
        assertEq(indexedPool.activeRawShares, 4 * G);
        assertEq(indexedPool.rewardRawShares, 0);
        assertEq(eventCount[I.RewardsCheckpointed.selector], 4);
        vm.recordLogs();
        she.checkpointRewards();
        assertEq(vm.getRecordedLogs().length, 0, "no-op checkpoint emitted accounting changes");
    }

    function testFuzz_replayDonationAndWithdrawalRounding(uint64 amountSeed, uint64 donationSeed, uint16 partSeed)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 2, 10 ether);
        uint256 donation = bound(uint256(donationSeed), 1, 10 ether);
        vm.recordLogs();
        deposit(alice, amount);
        deposit(bob, amount);
        replay();
        donate(donation);
        vm.recordLogs();
        uint256 units = indexedUnits[alice] * bound(uint256(partSeed), 5000, 9999) / 10_000;
        uint256 id = request(alice, units);
        replay();
        uint256 q = units * ((2 * amount + donation) * G) / (2 * amount * G);
        assertEq(indexedRequests[id].rawShares, q);
        vm.warp(block.timestamp + 10);
        vm.recordLogs();
        vm.prank(distributor);
        she.executeWithdrawal(id, q / G);
        replay();
        assertEq(indexedPool.activeRawShares, (2 * amount + donation) * G - (q / G) * G);
        assertEq(indexedPool.requestedRawShares, 0);
        assertEq(indexedPool.rewardRawShares, 0);
        assertEq(indexedUnits[alice], amount * G - SEED - units);
    }

    function replay() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(she)) continue;
            bytes32 topic = logs[i].topics[0];
            ++eventCount[topic];
            if (topic == I.Deposited.selector) readDeposit(logs[i]);
            else if (topic == I.SeedLocked.selector) readSeed(logs[i]);
            else if (topic == I.WithdrawalRequested.selector) readRequest(logs[i]);
            else if (topic == I.WithdrawalCancelled.selector) readCancellation(logs[i]);
            else if (topic == I.WithdrawalExecuted.selector) readExecution(logs[i]);
            else if (topic == I.RewardsFunded.selector) readFunding(logs[i]);
            else if (topic == I.RewardsCheckpointed.selector) readCheckpoint(logs[i]);
            else revert("unexpected SHE event");
        }
        assertReplay();
    }

    function readDeposit(Vm.Log memory log) private {
        assertEq(log.topics.length, 3);
        (uint256 amount, uint256 units, I.AccountBalance memory account, I.Accounting memory a) =
            abi.decode(log.data, (uint256, uint256, I.AccountBalance, I.Accounting));
        assertGt(amount, 0);
        address owner = address(uint160(uint256(log.topics[2])));
        if (eventCount[I.Deposited.selector] == 1) {
            assertEq(abi.encode(a), abi.encode(indexedPool), "seed and initial deposit snapshots differ");
        } else {
            assertEq(a.activeRawShares, indexedPool.activeRawShares + amount * G);
            assertEq(a.totalOwnershipUnits, indexedPool.totalOwnershipUnits + units);
            assertEq(a.requestedRawShares, indexedPool.requestedRawShares);
            assertEq(a.rewardRawShares, indexedPool.rewardRawShares);
        }
        indexedUnits[owner] += units;
        acceptAccount(owner, account, a);
    }

    function readSeed(Vm.Log memory log) private {
        assertEq(log.topics.length, 2);
        (uint256 units, I.AccountBalance memory account, I.Accounting memory a) =
            abi.decode(log.data, (uint256, I.AccountBalance, I.Accounting));
        address owner = address(uint160(uint256(log.topics[1])));
        assertEq(owner, address(1));
        assertEq(units, SEED);
        assertEq(indexedUnits[owner], 0);
        indexedUnits[owner] = units;
        acceptAccount(owner, account, a);
    }

    function readRequest(Vm.Log memory log) private {
        assertEq(log.topics.length, 3);
        (uint256 units, uint256 raw, uint64 eligibleAt, I.AccountBalance memory account, I.Accounting memory a) =
            abi.decode(log.data, (uint256, uint256, uint64, I.AccountBalance, I.Accounting));
        uint256 id = uint256(log.topics[1]);
        address owner = address(uint160(uint256(log.topics[2])));
        assertEq(uint256(indexedRequests[id].status), uint256(I.RequestStatus.NONE));
        indexedRequests[id] =
            I.WithdrawalRequest(owner, raw, uint64(block.timestamp), eligibleAt, I.RequestStatus.REQUESTED);
        indexedPending[owner] += raw;
        indexedUnits[owner] -= units;
        acceptAccount(owner, account, a);
    }

    function readCancellation(Vm.Log memory log) private {
        assertEq(log.topics.length, 3);
        (uint256 raw, uint256 units, I.AccountBalance memory account, I.Accounting memory a) =
            abi.decode(log.data, (uint256, uint256, I.AccountBalance, I.Accounting));
        uint256 id = uint256(log.topics[1]);
        address owner = address(uint160(uint256(log.topics[2])));
        resolveRequest(id, owner, raw, I.RequestStatus.CANCELLED);
        indexedUnits[owner] += units;
        acceptAccount(owner, account, a);
    }

    function readExecution(Vm.Log memory log) private {
        assertEq(log.topics.length, 3);
        (uint256 amount, uint256 raw, I.AccountBalance memory account, I.Accounting memory a) =
            abi.decode(log.data, (uint256, uint256, I.AccountBalance, I.Accounting));
        uint256 id = uint256(log.topics[1]);
        address owner = address(uint160(uint256(log.topics[2])));
        assertGe(block.timestamp, indexedRequests[id].eligibleAt);
        assertEq(amount, raw / G);
        resolveRequest(id, owner, raw, I.RequestStatus.EXECUTED);
        acceptAccount(owner, account, a);
    }

    function resolveRequest(uint256 id, address owner, uint256 raw, I.RequestStatus status) private {
        I.WithdrawalRequest storage r = indexedRequests[id];
        assertEq(r.owner, owner);
        assertEq(r.rawShares, raw);
        assertEq(uint256(r.status), uint256(I.RequestStatus.REQUESTED));
        indexedPending[owner] -= raw;
        r.status = status;
    }

    function readFunding(Vm.Log memory log) private {
        (uint256 amount, uint256 received, uint256 scheduled, uint64 start, uint64 end, I.Accounting memory a) =
            abi.decode(log.data, (uint256, uint256, uint256, uint64, uint64, I.Accounting));
        assertGt(amount, 0);
        assertGt(received, 0);
        assertEq(scheduled, indexedPool.rewardRawShares + received);
        assertEq(a.rewardRawShares, scheduled);
        assertEq(a.activeRawShares, indexedPool.activeRawShares);
        assertEq(a.totalOwnershipUnits, indexedPool.totalOwnershipUnits);
        assertEq(a.requestedRawShares, indexedPool.requestedRawShares);
        assertEq(start, block.timestamp);
        assertGt(end, start);
        indexedStream = I.RewardStream(scheduled, 0, start, end);
        indexedPool = a;
    }

    function readCheckpoint(Vm.Log memory log) private {
        (uint256 allocated, uint256 retained, uint256 released, I.Accounting memory a) =
            abi.decode(log.data, (uint256, uint256, uint256, I.Accounting));
        assertEq(released, elapsedRelease());
        uint256 emission = released - indexedStream.releasedRawShares;
        uint256 surplus = allocated + retained - emission;
        assertEq(a.totalOwnershipUnits, indexedPool.totalOwnershipUnits);
        assertEq(a.activeRawShares, indexedPool.activeRawShares + allocated);
        if (a.totalOwnershipUnits > SEED) {
            assertEq(retained, 0);
            assertEq(a.rewardRawShares, indexedPool.rewardRawShares - emission);
        } else {
            assertEq(allocated, 0);
            assertEq(a.rewardRawShares, indexedPool.rewardRawShares + surplus);
        }
        // During execution, Q already excludes the settled request; its final event resolves the owner ledger.
        indexedPool = a;
        indexedStream.releasedRawShares = released;
    }

    function acceptAccount(address owner, I.AccountBalance memory account, I.Accounting memory a) private {
        assertEq(account.ownershipUnits, indexedUnits[owner]);
        assertEq(account.activeRawShares, indexedUnits[owner] * a.activeRawShares / a.totalOwnershipUnits);
        indexedPool = a;
    }

    function elapsedRelease() private view returns (uint256) {
        if (indexedStream.end == 0 || block.timestamp <= indexedStream.start) return 0;
        uint256 until = block.timestamp < indexedStream.end ? block.timestamp : indexedStream.end;
        return indexedStream.totalRawShares * (until - indexedStream.start) / (indexedStream.end - indexedStream.start);
    }

    function effectivePool() private view returns (I.Accounting memory a) {
        a = indexedPool;
        if (a.totalOwnershipUnits > SEED) {
            uint256 pending = elapsedRelease() - indexedStream.releasedRawShares;
            a.activeRawShares += pending;
            a.rewardRawShares -= pending;
        }
    }

    function assertReplay() private view {
        I.Accounting memory a = effectivePool();
        assertEq(abi.encode(a), abi.encode(she.totalAccounting()));
        assertEq(a.activeRawShares + a.requestedRawShares + a.rewardRawShares, token.sharesOf(address(she)));
        assertEq(a.totalOwnershipUnits, indexedUnits[alice] + indexedUnits[bob] + indexedUnits[address(1)]);
        assertEq(a.requestedRawShares, indexedPending[alice] + indexedPending[bob]);
        address[3] memory owners = [alice, bob, address(1)];
        for (uint256 i; i < owners.length; ++i) {
            (uint256 units, uint256 raw, uint256 wrapped) = she.account(owners[i]);
            assertEq(units, indexedUnits[owners[i]]);
            assertEq(raw, units == 0 ? 0 : units * a.activeRawShares / a.totalOwnershipUnits);
            assertEq(wrapped, raw / G);
        }
    }
}
