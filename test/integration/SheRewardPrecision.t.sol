// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";

contract SheRewardPrecisionTest is SheAssertions {
    function test_liquidityFixturePreservesClockAndUnprocessedRewardSchedule() public {
        deposit(alice, 10 ether);
        uint256 id = request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(1005);
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        bytes32 streamBefore = rewardSnapshot();
        bytes memory storedBefore = abi.encode(storedAccounting());
        uint256 custody = token.sharesOf(address(she));
        assertEq(she.totalAccounting().activeRawShares, 8.2 ether * 1e6);
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), 0);
        setLiquidity(1 ether);
        assertEq(block.timestamp, 1005);
        assertEq(rewardSnapshot(), streamBefore);
        assertEq(abi.encode(storedAccounting()), storedBefore);
        assertEq(token.sharesOf(address(she)), custody);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);
        assertEq(she.totalAccounting().activeRawShares, 8.2 ether * 1e6);
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), 0);
        (bool eligible, uint256 amount) = lens.previewExecution(she, id);
        assertFalse(eligible);
        assertEq(amount, 2 ether);
        vm.expectEmit(address(she));
        emitExpectedRewardsCheckpointed(0.2 ether * 1e6, 0);
        she.checkpointRewards();
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(8.2 ether * 1e6, 8 ether * 1e6, 2 ether * 1e6, 3.8 ether * 1e6))
        );
        backed();
    }

    struct Schedule {
        uint256 active;
        uint256 queued;
        uint256 start;
        uint256 duration;
        uint256 funded;
        uint256 held;
        bool seedOnly;
        bytes original;
    }

    function testFuzz_partitionedCheckpointsMatchSingleCheckpoint(
        uint64 fundingSeed,
        uint32 durationSeed,
        uint32 timeSeed,
        bool seedOnly
    ) public {
        Schedule memory s;
        uint256 units = deposit(alice, 10 ether);
        request(alice, seedOnly ? units : 4 ether * 1e6);
        s.active = seedOnly ? SEED : 6 ether * 1e6;
        s.queued = seedOnly ? units : 4 ether * 1e6;
        s.duration = bound(uint256(durationSeed), 1, 7 days);
        s.funded = bound(uint256(fundingSeed), 1, 10 ether) * 1e6;
        s.seedOnly = seedOnly;
        uint256 elapsed = bound(uint256(timeSeed), 0, s.duration + 1);
        she.setRewardDuration(uint64(s.duration));
        fund(s.funded / 1e6);
        s.start = block.timestamp;
        s.held = token.sharesOf(address(she));
        s.original = abi.encode(she.getWithdrawalRequest(1));
        vm.prank(manager);
        she.setPaused(true);
        assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(s.active, s.active, s.queued, s.funded)));
        uint256 branch = vm.snapshot();
        uint256 processed;
        for (uint256 i; i <= 8; ++i) {
            uint256 step = elapsed * i / 8;
            vm.warp(s.start + step);
            uint256 emission = s.funded * (step > s.duration ? s.duration : step) / s.duration;
            assertCheckpoint(s, processed, emission);
            processed = emission;
        }
        bytes32 partitioned = snapshot();
        assertTrue(vm.revertTo(branch));
        vm.warp(s.start + elapsed);
        she.checkpointRewards();
        assertEq(snapshot(), partitioned, "checkpoint frequency changes final state");
        backed();
    }

    function assertCheckpoint(Schedule memory s, uint256 processed, uint256 emission) private {
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), processed);
        if (emission != processed) {
            vm.expectEmit(address(she));
            emitExpectedRewardsCheckpointed(
                s.seedOnly ? 0 : emission - processed, s.seedOnly ? emission - processed : 0
            );
        }
        // This unprivileged caller has no position or operational role, even while paused.
        vm.prank(bob);
        she.checkpointRewards();
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(
                I.Accounting(
                    s.active + (s.seedOnly ? 0 : emission), s.active, s.queued, s.funded - (s.seedOnly ? 0 : emission)
                )
            )
        );
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(
            abi.encode(stream),
            abi.encode(I.RewardStream(s.funded, emission, uint64(s.start), uint64(s.start + s.duration)))
        );
        assertEq(retained, s.seedOnly ? emission : 0);
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), emission);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), s.original);
        assertEq(token.sharesOf(address(she)), s.held);
        assertTrue(she.paused());
        bytes32 before = snapshot();
        vm.recordLogs();
        she.checkpointRewards();
        assertEq(vm.getRecordedLogs().length, 0, "same-timestamp checkpoint emitted again");
        assertEq(snapshot(), before, "same-timestamp checkpoint changed state");
    }

    function test_fractionalRawShareEmissionIsRetainedAcrossEmptyBoundaryAndRescheduledExactly() public {
        uint256 units = deposit(alice, 2);
        she.setRewardDuration(97);
        fund(1);
        assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(2e6, 2e6, 0, 1e6)));
        vm.warp(1001);
        // floor(1e6 / 97) = 10309; the next interval's fractional carry must not be discarded.
        uint256 raw = units * 2_010_309 / 2e6;
        uint256 id = request(alice, units);
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        uint256 locked = 2_010_309 - raw;
        assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(locked, SEED, raw, 989_691)));
        vm.warp(1002);
        vm.expectEmit(address(she));
        emitExpectedRewardsCheckpointed(0, 10_309);
        she.checkpointRewards();
        (, uint256 retained) = she.rewardState();
        assertEq(retained, 10_309);
        // Refill after the empty interval cannot capture its retained emission.
        uint256 fresh = deposit(bob, 2);
        assertEq(fresh, uint256(2e6) * SEED / locked);
        vm.warp(1003);
        she.checkpointRewards();
        assertEq(storedAccounting().activeRawShares, locked + 2e6 + 10_309);
        vm.warp(1004);
        vm.expectEmit(address(she));
        emitExpectedRewardsCheckpointed(10_310, 0);
        she.checkpointRewards();
        assertEq(
            abi.encode(storedAccounting()), abi.encode(I.Accounting(locked + 2e6 + 20_619, SEED + fresh, raw, 969_072))
        );
        vm.warp(1097);
        she.checkpointRewards();
        assertEq(storedAccounting().activeRawShares, locked + 2e6 + 979_382);
        assertEq(storedAccounting().rewardRawShares, 10_309);
        fund(1);
        (I.RewardStream memory stream, uint256 remaining) = she.rewardState();
        assertEq(abi.encode(stream), abi.encode(I.RewardStream(1_010_309, 0, 1097, 1194)));
        assertEq(remaining, 0);
        vm.warp(1194);
        she.checkpointRewards();
        assertEq(
            abi.encode(storedAccounting()), abi.encode(I.Accounting(locked + 2e6 + 1_989_691, SEED + fresh, raw, 0))
        );
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        assertEq(token.sharesOf(address(she)), 6e6);
        assertEq(alice.balance, 0);
        assertEq(bob.balance, 0);
        assertFalse(she.isLocked());
        backed();
    }
}
