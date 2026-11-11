// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {Overseer} from "../../src/Overseer.sol";

// Losses are injected into local backing;
// these tests do not model how a production staking module incurs a loss.
contract SheSlashingTest is SheAssertions {
    function _applyLoss(uint256 lossBps) internal {
        vm.warp(block.timestamp > token.syncEnd() ? block.timestamp : token.syncEnd() + 1);
        vm.deal(address(overseer), address(overseer).balance * (10_000 - lossBps) / 10_000);
        overseer.rebase();
    }

    function testFuzz_SlashPreservesBucketsAndAllowsWithdrawal(uint16 lossSeed) public {
        uint256 lossBps = bound(uint256(lossSeed), 1, 9_999);
        overseer.setMaxSlashPercentage(1e18);
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        uint256 id = request(alice, 4 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 50);

        I.Accounting memory before = she.totalAccounting();
        (I.RewardStream memory streamBefore,) = she.rewardState();
        uint256 held = token.sharesOf(address(she));
        uint256 totalShares = token.totalShares();
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        _applyLoss(lossBps);

        assertFalse(overseer.pendingSlashExists());
        assertEq(token.totalShares(), totalShares);
        assertEq(token.sharesOf(address(she)), held);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
        (I.RewardStream memory streamAfter,) = she.rewardState();
        assertEq(abi.encode(streamAfter), abi.encode(streamBefore));
        assertEq(she.getWithdrawalRequest(id).rawShares, 4 ether * 1e6);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);

        // The minimum is denominated in wstHYPE and is unaffected by the loss.
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 4 ether + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );

        uint256 expectedPayout = 4 ether;
        executeAndAssertPayout(alice, id, expectedPayout);
        assertEq(wrapper.balanceOf(alice), expectedPayout);
        assertEq(token.balanceOf(alice), 4 ether * (10_000 - lossBps) / 10_000);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(she.totalAccounting().activeRawShares, before.activeRawShares);
        assertEq(she.totalAccounting().rewardRawShares, before.rewardRawShares);
        assertEq(she.totalAccounting().totalOwnershipUnits, before.totalOwnershipUnits);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        backed();
    }

    function testSlashPendingAllowsWstHypeExitAndOwnerRemainsExposedAfterRebase() public {
        overseer.setMaxSlashPercentage(0.1e18);
        uint256 id = request(alice, deposit(alice, 10 ether));
        deposit(bob, 10 ether);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        vm.deal(address(overseer), address(overseer).balance * 9 / 10);
        assertTrue(overseer.pendingSlashExists());
        assertEq(overseer.maxRedeemable(), 0);

        I.Accounting memory before = she.totalAccounting();
        uint256 held = token.sharesOf(address(she));
        vm.expectRevert(Overseer.CannotMintWhilePendingSlash.selector);
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(0);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
        assertEq(token.sharesOf(address(she)), held);

        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertEq(alice.balance, 0);
        overseer.rebase();
        assertFalse(overseer.pendingSlashExists());
        assertEq(overseer.getLatestCumulativeSlashFactor(), 0.9e18);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
        assertEq(token.balanceOf(alice), 9 ether - 1);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(she.totalAccounting().requestedRawShares, 0);

        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(1 ether * 1e6);
        assertGt(she.totalAccounting().rewardRawShares, 1 ether * 1e6);
        backed();
    }

    function testSlashCapRequiresOperatorActionWithoutCorruptingSHE() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        deposit(bob, 10 ether);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        I.WithdrawalRequest memory original = she.getWithdrawalRequest(id);
        I.Accounting memory before = she.totalAccounting();
        overseer.setMaxSlashPercentage(0.05e18);
        vm.deal(address(overseer), address(overseer).balance * 9 / 10);
        vm.expectRevert(abi.encodeWithSelector(Overseer.SupplyDecreaseTooHigh.selector, 0.1e18));
        overseer.rebase();
        assertTrue(overseer.pendingSlashExists());
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
        assertEq(she.getWithdrawalRequest(id).rawShares, 10 ether * 1e6 - SEED);

        // Checkpoints preserve the pending claim while the protocol awaits loss recognition.
        she.checkpointRewards();
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(original));
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));

        overseer.setMaxSlashPercentage(0.1e18);
        overseer.rebase();
        assertFalse(overseer.pendingSlashExists());
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(original));
        // Retry the original matured request without another cooldown.
        vm.prank(alice);
        she.executeWithdrawal(id, 10 ether - 1);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(she.totalAccounting().activeRawShares, before.activeRawShares + 1e6 - SEED);
        assertEq(she.totalAccounting().totalOwnershipUnits, before.totalOwnershipUnits);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        backed();
    }

    function testSlashTinyNominalRequestStillTransfersOneWstHypeWei() public {
        overseer.setMaxSlashPercentage(0.5e18 + 1);
        uint256 tiny = request(alice, deposit(alice, 2));
        uint256 bobUnits = deposit(bob, 10 ether);
        vm.warp(she.getWithdrawalRequest(tiny).eligibleAt);
        _applyLoss(5_000);
        assertEq(token.sharesToBalance(she.getWithdrawalRequest(tiny).rawShares), 0);
        executeAndAssertPayout(alice, tiny, 1);
        assertEq(wrapper.balanceOf(alice), 1);
        assertEq(token.balanceOf(alice), 0);
        uint256 big = request(bob, bobUnits);
        executeAndAssertPayout(bob, big, 10 ether);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        backed();
    }

    function testSlashRepeatedLossesDoNotResetRewardStream() public {
        overseer.setMaxSlashPercentage(0.5e18);
        deposit(alice, 10 ether);
        fund(2 ether);
        (I.RewardStream memory initial,) = she.rewardState();
        vm.warp(initial.start + 25);
        _applyLoss(1_000);
        she.checkpointRewards();
        assertEq(she.totalAccounting().activeRawShares, 10.5 ether * 1e6);
        assertEq(she.totalAccounting().rewardRawShares, 1.5 ether * 1e6);
        vm.warp(initial.start + 75);
        _applyLoss(2_000);
        she.checkpointRewards();
        assertEq(she.totalAccounting().activeRawShares, 11.5 ether * 1e6);
        assertEq(she.totalAccounting().rewardRawShares, 0.5 ether * 1e6);
        (I.RewardStream memory current,) = she.rewardState();
        assertEq(current.start, initial.start);
        assertEq(current.end, initial.end);
        assertEq(current.totalRawShares, initial.totalRawShares);
        vm.warp(initial.end);
        she.checkpointRewards();
        assertEq(she.totalAccounting().activeRawShares, 12 ether * 1e6);
        assertEq(she.totalAccounting().rewardRawShares, 0);

        uint256 expectedNewShares = token.balanceToShares(1 ether);
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(expectedNewShares);
        assertEq(she.totalAccounting().rewardRawShares, expectedNewShares);
        assertEq(she.totalAccounting().activeRawShares, 12 ether * 1e6);
        (current,) = she.rewardState();
        assertEq(current.totalRawShares, expectedNewShares);
        assertEq(current.end - current.start, 100);
        backed();
    }

    // Negative scenario: green means the upstream deadlock was reproduced,
    // not that total-loss recovery is supported.
    function testSlashTotalLossHasNoNormalProtocolRecovery() public {
        overseer.setMaxSlashPercentage(1e18);
        uint256 id = request(alice, deposit(alice, 10 ether));
        deposit(bob, 10 ether);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        I.Accounting memory before = she.totalAccounting();
        _applyLoss(10_000);
        assertEq(token.totalSupply(), 0);
        assertGt(token.totalShares(), 0);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 0);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
        uint256 held = token.sharesOf(address(she));
        uint256 shares = token.totalShares();
        uint256 count = overseer.burnCount();
        vm.prank(alice);
        assertEq(she.executeWithdrawal(id, 10 ether - 1), 10 ether - 1);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalShares(), shares);
        assertEq(token.sharesOf(address(she)), held - (10 ether - 1) * 1e6);
        assertEq(overseer.burnCount(), count);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        before.requestedRawShares = 0;
        before.activeRawShares += 1e6 - SEED;

        // FixedPointMathLib explicitly reverts with empty data for division by zero.
        vm.expectRevert(bytes(""));
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(0);
        assertEq(she.totalAccounting().rewardRawShares, 0);
        vm.deal(address(overseer), 1 ether); // Even recapitalizing backing does not repair the state.
        vm.warp(block.timestamp + 1);
        vm.expectRevert(stdError.divisionError);
        overseer.rebase();
        assertEq(token.totalSupply(), 0);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 0);
        she.checkpointRewards();
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        backed();
    }

    // A second negative scenario: a zero cumulative factor can outlive positive backing.
    function testSlashZeroCumulativeFactorDoesNotBlockWstHypeTransfer() public {
        overseer.setMaxSlashPercentage(0.6e18);
        uint256 id = request(alice, deposit(alice, 10 ether));
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        for (uint256 i; i < 60; ++i) {
            _applyLoss(5_000);
            if (i < 59) overseer.mint{value: 10 ether}(address(this));
        }
        assertGt(token.totalSupply(), 1 ether);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 0);
        uint256 shares = token.totalShares();
        uint256 supply = token.totalSupply();
        uint256 count = overseer.burnCount();
        vm.prank(alice);
        assertEq(she.executeWithdrawal(id, 10 ether - 1), 10 ether - 1);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
        assertEq(token.totalShares(), shares);
        assertEq(token.totalSupply(), supply);
        assertEq(overseer.burnCount(), count);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        backed();
    }
}
