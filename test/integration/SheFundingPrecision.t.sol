// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";

contract SheFundingPrecisionTest is SheAssertions {
    uint256 private constant G = 1e6;

    struct FundingCase {
        uint256 duration;
        uint256 elapsed;
        uint256 rewardPerSecond;
        uint256 amount;
        uint256 baseSupply;
        uint256 rawSupply;
        uint256 received;
        uint256 scheduled;
        uint256 held;
        bool seedOnly;
        bool paused;
        I.Accounting accounting;
        bytes requestBefore;
    }

    function test_fundingDuringFractionalUpstreamVestingUsesRawSupply() public {
        FundingCase memory c;
        c.duration = 300;
        c.elapsed = 100;
        c.amount = 1 ether;
        runFundingCase(c);
    }

    function test_seedOnlyFundingExcludesRetainedRewardsFromMinimumDuringUpstreamVesting() public {
        FundingCase memory c;
        c.duration = 301;
        c.elapsed = 200;
        c.amount = 1 ether;
        c.seedOnly = true;
        c.paused = true;
        runFundingCase(c);
    }

    function test_oneWeiFundingCreditsRawSharesBelowOneWrapperWeiDuringUpstreamVesting() public {
        FundingCase memory c;
        c.duration = 7 days;
        c.elapsed = c.duration - 1;
        c.rewardPerSecond = 1e14;
        c.amount = 1;
        runFundingCase(c);
        assertGt(c.received, 0);
        assertLt(c.received, G, "funding must credit shares even when the wrapper balance does not increase");
    }

    function testFuzz_fundingAndSettlementDuringFractionalUpstreamVesting(
        uint32 durationSeed,
        uint32 elapsedSeed,
        uint64 rewardSeed,
        uint64 amountSeed,
        bool seedOnly,
        bool paused
    ) public {
        FundingCase memory c;
        c.duration = bound(uint256(durationSeed), 101, 7 days);
        c.elapsed = bound(uint256(elapsedSeed), 100, c.duration - 1);
        c.rewardPerSecond = bound(uint256(rewardSeed), 0, 1e14);
        c.amount = bound(uint256(amountSeed), 1, 10 ether);
        c.seedOnly = seedOnly;
        c.paused = paused;
        runFundingCase(c);
    }

    function runFundingCase(FundingCase memory c) private {
        uint256 units = deposit(alice, 10 ether);
        request(alice, c.seedOnly ? units : 2 ether * G);
        c.requestBefore = abi.encode(she.getWithdrawalRequest(1));
        fund(2 ether);
        donate(1 ether); // Leave surplus and the old stream uncheckpointed before both funding attempts.
        c.baseSupply = token.totalSupply();
        assertEq(c.baseSupply, 13.02 ether);
        uint256 rewards = c.rewardPerSecond * c.duration + 1;
        vm.deal(address(overseer), c.baseSupply + rewards);
        token.syncSupply(c.baseSupply + rewards, c.duration);
        she.setPaused(c.paused);
        vm.warp(1099);
        reject(
            distributor,
            c.amount,
            abi.encodeCall(I.fundRewards, (0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__StreamActive.selector)
        );
        vm.warp(1000 + c.elapsed);
        assertLt(block.timestamp, token.syncEnd());
        // Independently derive vesting, including a strictly fractional nominal wei. No token quote oracle.
        c.rawSupply = (c.baseSupply + c.rewardPerSecond * c.elapsed) * G + c.elapsed * G / c.duration;
        assertGt(c.rawSupply % G, 0);
        assertEq(token.totalSupplyRaw(), c.rawSupply);
        assertEq(token.totalSupply(), c.rawSupply / G);
        // Bounds above keep this numerator below uint256, including at the maximum reward rate.
        c.received = c.amount * (c.baseSupply * G) * G / c.rawSupply;
        assertGt(c.received, 0);
        reject(
            distributor,
            c.amount,
            abi.encodeCall(I.fundRewards, (c.received + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        c.scheduled = c.received + (c.seedOnly ? 3 ether * G : 0);
        c.accounting = I.Accounting(
            c.seedOnly ? SEED : 11 ether * G,
            c.seedOnly ? SEED : 8 ether * G,
            c.seedOnly ? units : 2 ether * G,
            c.scheduled
        );
        assertFunding(c);
        assertFundingCheckpointsAndSettlement(c);
    }

    function assertFunding(FundingCase memory c) private {
        c.held = token.sharesOf(address(she));
        assertEq(c.held, 13 ether * G);
        bytes32 unchanged = fundingUnchangedState();
        uint256 nativeBefore = distributor.balance;
        uint256 upstreamBefore = address(overseer).balance;
        uint64 start = uint64(block.timestamp);
        vm.expectEmit(address(she));
        emit I.RewardsFunded(c.amount, c.received, c.scheduled, start, start + 100, c.accounting);
        vm.prank(distributor);
        she.fundRewards{value: c.amount}(c.received);
        c.held += c.received;
        assertEq(abi.encode(storedAccounting()), abi.encode(c.accounting));
        assertEq(abi.encode(she.totalAccounting()), abi.encode(c.accounting));
        assertEq(token.sharesOf(address(she)), c.held);
        assertEq(wrapper.balanceOf(address(she)), c.held / G);
        assertEq(token.totalShares(), c.baseSupply * G + c.received);
        assertEq(token.preSyncSupply(), c.baseSupply + c.amount);
        assertEq(token.totalSupplyRaw(), c.rawSupply + c.amount * G);
        assertEq(token.totalSupply(), (c.rawSupply + c.amount * G) / G);
        assertEq(distributor.balance, nativeBefore - c.amount);
        assertEq(address(overseer).balance, upstreamBefore + c.amount);
        assertEq(fundingUnchangedState(), unchanged, "funding changed unrelated state");
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(abi.encode(stream), abi.encode(I.RewardStream(c.scheduled, 0, start, start + 100)));
        assertEq(retained, 0);
        assertFalse(she.isLocked());
        backed();
    }

    function assertFundingCheckpointsAndSettlement(FundingCase memory c) private {
        uint256 start = block.timestamp;
        bytes32 unchanged = fundingUnchangedState();
        uint256 shares = token.totalShares();
        uint256 nativeBefore = distributor.balance;
        uint256 upstreamBefore = address(overseer).balance;
        for (uint256 i = 1; i <= 2; ++i) {
            vm.warp(start + i * 50);
            uint256 released = c.scheduled * i / 2;
            I.Accounting memory expected = I.Accounting(
                c.accounting.activeRawShares + (c.seedOnly ? 0 : released),
                c.accounting.totalOwnershipUnits,
                c.accounting.requestedRawShares,
                c.scheduled - (c.seedOnly ? 0 : released)
            );
            assertEq(abi.encode(she.totalAccounting()), abi.encode(expected));
            uint256 previouslyReleased = c.scheduled * (i - 1) / 2;
            vm.expectEmit(address(she));
            emit I.RewardsCheckpointed(
                c.seedOnly ? 0 : released - previouslyReleased,
                c.seedOnly ? released - previouslyReleased : 0,
                released,
                expected
            );
            vm.prank(bob);
            she.checkpointRewards();
            assertEq(abi.encode(storedAccounting()), abi.encode(expected));
            (I.RewardStream memory stream, uint256 retained) = she.rewardState();
            assertEq(
                abi.encode(stream),
                abi.encode(I.RewardStream(c.scheduled, released, uint64(start), uint64(start + 100)))
            );
            assertEq(retained, c.seedOnly ? released : 0);
            assertEq(token.sharesOf(address(she)), c.held);
            assertEq(token.totalShares(), shares);
            assertEq(distributor.balance, nativeBefore);
            assertEq(address(overseer).balance, upstreamBefore);
            assertEq(fundingUnchangedState(), unchanged);
            assertEq(abi.encode(she.getWithdrawalRequest(1)), c.requestBefore);
            bytes32 beforeRepeat = snapshot();
            vm.recordLogs();
            she.checkpointRewards();
            assertEq(vm.getRecordedLogs().length, 0);
            assertEq(snapshot(), beforeRepeat);
            backed();
        }
        she.setPaused(false);
        uint256 raw = c.accounting.requestedRawShares;
        executeAndAssertPayout(alice, 1, raw / G);
        assertEq(storedAccounting().requestedRawShares, 0);
        assertEq(
            storedAccounting().rewardRawShares,
            c.seedOnly ? c.scheduled + raw % G : 0,
            "pending requests must not absorb rewards or lose settlement dust"
        );
    }

    function fundingUnchangedState() private view returns (bytes32 digest) {
        address[8] memory actors =
            [address(this), alice, bob, manager, distributor, upgradeGov, address(overseer), address(1)];
        for (uint256 i; i < actors.length; ++i) {
            (uint256 units,,) = she.account(actors[i]);
            digest = keccak256(
                abi.encode(
                    digest,
                    token.sharesOf(actors[i]),
                    wrapper.balanceOf(actors[i]),
                    units,
                    wrapper.allowance(actors[i], address(she)),
                    wrapper.allowance(address(she), actors[i]),
                    actors[i] == distributor || actors[i] == address(overseer) ? 0 : actors[i].balance
                )
            );
        }
        return keccak256(
            abi.encode(
                digest,
                she.configuration(),
                she.paused(),
                address(she).balance,
                she.getWithdrawalRequest(1),
                she.getWithdrawalRequest(2),
                vm.load(address(she), bytes32(SHE_SLOT + 12)),
                token.rewardsToSync(),
                token.syncStart(),
                token.syncEnd(),
                overseer.getAllBurns(),
                overseer.totalPendingBurns(),
                overseer.redeemed(),
                overseer.protocolPendingFee()
            )
        );
    }
}
