// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {IStakedHypeEscrowToken} from "../../src/interfaces/IStakedHypeEscrowDependencies.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract SheCancellationTest is SheAssertions {
    uint256 constant G = 1e6;

    struct CancelSnapshot {
        I.WithdrawalRequest original;
        bytes32 assets;
        bytes32 rewards;
        bytes config;
        uint256 count;
        bytes[] otherRequests;
        uint256 ownerUnits;
        address otherOwner;
        uint256 otherUnits;
    }

    function custodySnapshot() private view returns (bytes32 digest) {
        address[9] memory actors =
            [address(this), alice, bob, manager, distributor, upgradeGov, address(she), address(overseer), address(1)];
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            digest = keccak256(
                abi.encode(
                    digest,
                    actor.balance,
                    token.sharesOf(actor),
                    wrapper.balanceOf(actor),
                    wrapper.allowance(actor, address(she))
                )
            );
        }
        digest = keccak256(
            abi.encode(
                digest,
                token.totalShares(),
                token.totalSupply(),
                token.preSyncSupply(),
                token.rewardsToSync(),
                token.syncStart(),
                token.syncEnd()
            )
        );
        digest = keccak256(
            abi.encode(
                digest,
                overseer.getAllBurns(),
                overseer.redeemed(),
                overseer.getNormalizedRedeemedHype(),
                overseer.getLatestCumulativeSlashFactor(),
                overseer.protocolPendingFee(),
                overseer.getTotalBalance(),
                wrapper.allowance(address(she), address(overseer))
            )
        );
    }

    function cancelAndAssert(address owner, uint256 id, uint256 units, I.Accounting memory expected) private {
        CancelSnapshot memory before;
        before.original = she.getWithdrawalRequest(id);
        assertEq(before.original.owner, owner);
        assertEq(uint256(before.original.status), uint256(I.RequestStatus.REQUESTED));
        before.assets = custodySnapshot();
        before.rewards = rewardSnapshot();
        before.config = abi.encode(she.configuration());
        before.count = uint256(vm.load(address(she), bytes32(SHE_SLOT + 12)));
        before.otherRequests = new bytes[](before.count + 1);
        for (uint256 i = 1; i <= before.count; ++i) {
            before.otherRequests[i] = abi.encode(she.getWithdrawalRequest(i));
        }
        (before.ownerUnits,,) = she.account(owner);
        before.otherOwner = owner == alice ? bob : alice;
        (before.otherUnits,,) = she.account(before.otherOwner);
        assertEq(lens.previewCancelWithdrawal(she, id), units);
        vm.recordLogs();
        vm.prank(owner);
        assertEq(she.cancelWithdrawal(id, units), units);
        assertCancellationEvent(vm.getRecordedLogs(), id, owner, before.original.rawShares, units);
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        assertEq(abi.encode(she.totalAccounting()), abi.encode(expected));
        assertEq(custodySnapshot(), before.assets, "cancellation moved assets or changed upstream accounting");
        assertEq(rewardSnapshot(), before.rewards, "cancellation changed the reward schedule");
        assertEq(abi.encode(she.configuration()), before.config);
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 12))), before.count);
        (uint256 ownerAfter,,) = she.account(owner);
        (uint256 otherUnitsAfter,,) = she.account(before.otherOwner);
        (uint256 seedUnits,,) = she.account(address(1));
        assertEq(ownerAfter, before.ownerUnits + units);
        assertEq(otherUnitsAfter, before.otherUnits);
        assertEq(seedUnits, SEED);
        before.original.status = I.RequestStatus.CANCELLED;
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(before.original));
        for (uint256 i = 1; i <= before.count; ++i) {
            if (i != id) assertEq(abi.encode(she.getWithdrawalRequest(i)), before.otherRequests[i]);
        }
        assertEq(lens.previewCancelWithdrawal(she, id), 0);
        (bool eligible, uint256 amount) = lens.previewExecution(she, id);
        assertFalse(eligible);
        assertEq(amount, 0);
        assertFalse(she.isLocked());
        backed();
    }

    function assertCancellationEvent(Vm.Log[] memory logs, uint256 id, address owner, uint256 raw, uint256 units)
        private
        view
    {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(she) || logs[i].topics.length == 0
                    || logs[i].topics[0] != I.WithdrawalCancelled.selector
            ) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(owner))));
            (uint256 ownerUnits, uint256 ownerRaw,) = she.account(owner);
            assertEq(
                logs[i].data, abi.encode(raw, units, I.AccountBalance(ownerUnits, ownerRaw), she.totalAccounting())
            );
            ++found;
        }
        assertEq(found, 1, "expected exactly one cancellation event");
    }

    function depositAtCurrentRate(address owner) private returns (uint256 units) {
        overseer.mint{value: 1 ether}(owner);
        uint256 rawBefore = token.sharesOf(owner);
        uint256 amount = rawBefore / G;
        uint256 heldBefore = token.sharesOf(address(she));
        I.Accounting memory expected = storedAccounting();
        assertEq(expected.activeRawShares, expected.totalOwnershipUnits);
        (uint256 ownerBefore,,) = she.account(owner);
        uint256 expectedUnits = amount * G - (expected.totalOwnershipUnits == 0 ? SEED : 0);
        vm.startPrank(owner);
        wrapper.approve(address(she), amount);
        uint256 accepted;
        (units, accepted) = she.deposit(amount, owner, expectedUnits, amount);
        vm.stopPrank();
        assertEq(units, expectedUnits);
        assertEq(accepted, amount);
        assertEq(token.sharesOf(owner), rawBefore % G);
        assertEq(wrapper.balanceOf(owner), 0);
        assertEq(wrapper.allowance(owner, address(she)), 0);
        assertEq(token.sharesOf(address(she)), heldBefore + amount * G);
        expected.activeRawShares += amount * G;
        expected.totalOwnershipUnits += amount * G;
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        (uint256 ownerAfter,,) = she.account(owner);
        assertEq(ownerAfter, ownerBefore + units);
        backed();
    }

    function rejectCancel(address caller, uint256 id, uint256 minimum, bytes4 reason) private {
        reject(caller, 0, abi.encodeCall(I.cancelWithdrawal, (id, minimum)), abi.encodeWithSelector(reason));
    }

    function test_cancelBeforeMaturityAndRerequestStartsANewCooldown() public {
        deposit(alice, 10 ether);
        uint256 id = request(alice, 4 ether * G);
        uint64 originalMaturity = she.getWithdrawalRequest(id).eligibleAt;
        vm.warp(block.timestamp + 5);
        assertLt(block.timestamp, originalMaturity);
        cancelAndAssert(alice, id, 4 ether * G, I.Accounting(10 ether * G, 10 ether * G, 0, 0));
        rejectCancel(alice, id, 0, I.StakedHypeEscrow__InvalidRequest.selector);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );

        she.setCooldown(20);
        uint256 next = request(alice, 4 ether * G);
        assertEq(next, id + 1);
        assertEq(she.getWithdrawalRequest(next).requestedAt, block.timestamp);
        assertEq(she.getWithdrawalRequest(next).eligibleAt, block.timestamp + 20);
        assertGt(she.getWithdrawalRequest(next).eligibleAt, originalMaturity);
        vm.warp(originalMaturity);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (next, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        executeAndAssertPayout(alice, next, 4 ether);
        rejectCancel(alice, next, 0, I.StakedHypeEscrow__InvalidRequest.selector);
    }

    function test_matureCancellationExcludesPriorRewardsAndDonationsAndEarnsFutureRewards() public {
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        uint256 id = request(alice, 4 ether * G);
        fund(4 ether);
        vm.warp(block.timestamp + 50);
        donate(2 ether);
        assertGt(block.timestamp, she.getWithdrawalRequest(id).eligibleAt);
        // Before cancellation A = 16 + 2 elapsed + 2 donated, U = 16; four returning shares buy 3.2 units.
        uint256 issued = 3.2 ether * G;
        rejectCancel(alice, id, issued + 1, I.StakedHypeEscrow__MinimumNotMet.selector);
        cancelAndAssert(alice, id, issued, I.Accounting(24 ether * G, 19.2 ether * G, 0, 2 ether * G));
        (, uint256 bobAssets,) = she.account(bob);
        assertEq(bobAssets, 12.5 ether * G, "returning shares diluted prior rewards");
        vm.warp(block.timestamp + 50);
        she.checkpointRewards();
        assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(26 ether * G, 19.2 ether * G, 0, 0)));
        uint256 returningEntitlement = issued * (26 ether * G) / (19.2 ether * G);
        assertGt(returningEntitlement, 4 ether * G);
        (uint256 aliceUnits, uint256 aliceAssets,) = she.account(alice);
        assertEq(aliceUnits, 9.2 ether * G - SEED);
        assertEq(aliceAssets, aliceUnits * (26 ether * G) / (19.2 ether * G));
        backed();
    }

    function test_seedOnlyCancellationRetainsEmptyPeriodRewardsAndAllRequestDust() public {
        uint256 units = deposit(alice, 10 ether);
        uint256 id = request(alice, units);
        assertEq(she.getWithdrawalRequest(id).rawShares % G, G - SEED);
        fund(4 ether);
        donate(2 ether);
        vm.warp(block.timestamp + 50);
        cancelAndAssert(alice, id, units, I.Accounting(10 ether * G, 10 ether * G, 0, 6 ether * G));
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), 2 ether * G);
        vm.warp(block.timestamp + 50);
        she.checkpointRewards();
        assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(12 ether * G, 10 ether * G, 0, 4 ether * G)));
        fund(1 ether);
        (I.RewardStream memory stream,) = she.rewardState();
        assertEq(stream.totalRawShares, 5 ether * G);
        vm.warp(stream.end);
        she.checkpointRewards();
        assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(17 ether * G, 10 ether * G, 0, 0)));
        (uint256 seedUnits,,) = she.account(address(1));
        assertEq(seedUnits, SEED);
        backed();
    }

    function test_onlyOwnerCanCancelAndPauseRejectsBeforeAccountingChanges() public {
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        uint256 id = request(alice, 4 ether * G);
        uint256 other = request(bob, 2 ether * G);
        fund(2 ether);
        vm.warp(block.timestamp + 50);
        donate(1 ether);
        address[4] memory callers = [bob, manager, distributor, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            rejectCancel(callers[i], id, 0, I.StakedHypeEscrow__OnlyRequestOwner.selector);
        }
        rejectCancel(alice, 0, 0, I.StakedHypeEscrow__InvalidRequest.selector);
        rejectCancel(alice, other + 1, 0, I.StakedHypeEscrow__InvalidRequest.selector);
        vm.prank(manager);
        she.setPaused(true);
        rejectCancel(alice, id, 0, I.StakedHypeEscrow__Paused.selector);
        she.setPaused(false);
        // A = 14 + 1 elapsed + 1 donation; U = 14. Cancellation leaves the other two-share request intact.
        cancelAndAssert(alice, id, 3.5 ether * G, I.Accounting(20 ether * G, 17.5 ether * G, 2 ether * G, 1 ether * G));
        executeAndAssertPayout(bob, other, 2 ether);
    }

    function test_zeroUnitCancellationPreservesTheOriginalWithdrawableClaim() public {
        deposit(alice, 2);
        uint256 id = request(alice, G);
        donate(2 ether);
        assertEq(lens.previewCancelWithdrawal(she, id), 0);
        rejectCancel(alice, id, 0, I.StakedHypeEscrow__InvalidAmount.selector);
        assertEq(she.getWithdrawalRequest(id).rawShares, G);
        assertEq(storedAccounting().requestedRawShares, G);
        executeAndAssertPayout(alice, id, 1);
    }

    function test_cancellationDoesNotDependOnNominalValueOrTokenTransfers() public {
        for (uint256 i; i < 2; ++i) {
            uint256 state = vm.snapshot();
            deposit(alice, 4 ether);
            deposit(bob, 4 ether);
            uint256 id = request(alice, 3 ether * G);
            token.syncSupply(i == 0 ? 0 : token.totalSupply() * 100_000_000, 0);
            uint256 nominal = token.sharesToBalance(she.getWithdrawalRequest(id).rawShares);
            if (i == 0) assertEq(nominal, 0);
            else assertEq(nominal, 300_000_000 ether);
            vm.mockCallRevert(
                address(token),
                abi.encodeWithSelector(IStakedHypeEscrowToken.sharesToBalance.selector),
                bytes("no nominal conversion")
            );
            vm.mockCallRevert(address(wrapper), abi.encodeWithSelector(IERC20.transfer.selector), bytes("no transfer"));
            vm.mockCallRevert(
                address(wrapper), abi.encodeWithSelector(IERC20.transferFrom.selector), bytes("no transferFrom")
            );
            cancelAndAssert(alice, id, 3 ether * G, I.Accounting(8 ether * G, 8 ether * G, 0, 0));
            vm.clearMockedCalls();
            assertTrue(vm.revertTo(state));
        }
    }

    function test_dependencyFailureAndInsolvencyLeaveCancellationRetryable() public {
        uint256 units = deposit(alice, 10 ether);
        uint256 id = request(alice, units);
        fund(2 ether);
        vm.warp(block.timestamp + 50);
        donate(1 ether);
        bytes32 beforeState = snapshot();
        bytes memory read = abi.encodeCall(IStakedHypeEscrowToken.sharesOf, (address(she)));
        bytes memory reason = abi.encodeWithSelector(bytes4(keccak256("Unavailable()")));
        vm.mockCallRevert(address(token), read, reason);
        vm.expectRevert(reason);
        vm.prank(alice);
        she.cancelWithdrawal(id, 0);
        vm.clearMockedCalls();
        assertEq(snapshot(), beforeState);
        vm.mockCall(address(token), read, abi.encode(uint256(0)));
        vm.expectRevert(I.StakedHypeEscrow__AccountingInvariant.selector);
        vm.prank(alice);
        she.cancelWithdrawal(id, 0);
        vm.clearMockedCalls();
        assertEq(snapshot(), beforeState);
        cancelAndAssert(alice, id, units, I.Accounting(10 ether * G, 10 ether * G, 0, 3 ether * G));
    }

    function test_cancelUsesFullPrecisionAfterRepeatedLossAndMint() public {
        overseer.setMaxSlashPercentage(0.6e18);
        // Reach a large raw-share scale through local protocol calls, without editing SHE storage.
        // Nominal supply stays small as new HYPE is minted after each simulated backing loss.
        for (uint256 i; i < 55; ++i) {
            vm.warp(token.syncEnd() + 1);
            vm.deal(address(overseer), address(overseer).balance / 2);
            overseer.rebase();
            overseer.mint{value: 1 ether}(address(this));
        }
        uint256 aliceUnits = depositAtCurrentRate(alice);
        uint256 bobUnits = depositAtCurrentRate(bob);
        uint256 raw = aliceUnits / 2;
        uint256 id = request(alice, raw);
        uint256 otherRaw = bobUnits / 4;
        uint256 otherId = request(bob, otherRaw);
        I.Accounting memory expected = storedAccounting();
        assertEq(expected.activeRawShares, expected.totalOwnershipUnits);
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        assertEq(she.getWithdrawalRequest(otherId).rawShares, otherRaw);
        assertEq(expected.requestedRawShares, raw + otherRaw);
        assertGt(raw, type(uint256).max / expected.totalOwnershipUnits, "intermediate product must overflow");
        assertGt(token.sharesToBalance(raw), 0);
        assertLt(token.totalSupply(), 5 ether);
        // A == U makes the independent floor quotient exactly q, despite q * U exceeding 256 bits.
        rejectCancel(alice, id, raw + 1, I.StakedHypeEscrow__MinimumNotMet.selector);
        expected.activeRawShares += raw;
        expected.totalOwnershipUnits += raw;
        expected.requestedRawShares = otherRaw;
        cancelAndAssert(alice, id, raw, expected);
        (uint256 restoredUnits,,) = she.account(alice);
        assertEq(restoredUnits, aliceUnits);
        rejectCancel(alice, id, 0, I.StakedHypeEscrow__InvalidRequest.selector);
    }

    function testFuzz_cancelQuoteWithOverflowingIntermediateAndNonzeroRemainder(
        uint144 rawSeed,
        uint8 rateSeed,
        uint8 remainderSeed
    ) public {
        // A controlled upstream loss supplies large real share balances cheaply. The separate
        // repeated-loss regression covers public Overseer rebase/mint history at this scale.
        token.syncSupply(1, 0);
        vm.deal(address(overseer), 1);
        depositAtCurrentRate(alice);
        depositAtCurrentRate(bob);
        uint256 rate = bound(uint256(rateSeed), 2, 255);
        uint256 remainder = bound(uint256(remainderSeed), 1, rate - 1);
        uint256 raw = bound(uint256(rawSeed), 1 << 129, 1 << 132);
        raw = raw / rate * rate + remainder;
        uint256 id = request(alice, raw);
        // Keep A == U divisible by the wrapper quantum, so a real donation can set A == rate * U.
        uint256 otherRaw = (uint256(1) << 130) / G * G + (G - raw % G) % G;
        uint256 otherId = request(bob, otherRaw);
        I.Accounting memory expected = storedAccounting();
        assertEq(expected.activeRawShares, expected.totalOwnershipUnits);
        assertEq(expected.activeRawShares % G, 0);
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        assertEq(she.getWithdrawalRequest(otherId).rawShares, otherRaw);
        assertEq(expected.requestedRawShares, raw + otherRaw);
        overseer.mint{value: 510 ether}(address(this));
        assertTrue(wrapper.transfer(address(she), expected.activeRawShares / G * (rate - 1)));
        she.checkpointRewards();
        expected.activeRawShares *= rate;
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        assertGt(raw, type(uint256).max / expected.totalOwnershipUnits, "intermediate product must overflow");
        // q * U / (rate * U) == q / rate: no Math.mulDiv or overflowing product in the oracle.
        uint256 units = raw / rate;
        assertEq(raw - units * rate, remainder);
        assertLt(units * rate, raw);
        assertGt((units + 1) * rate, raw);
        rejectCancel(alice, id, units + 1, I.StakedHypeEscrow__MinimumNotMet.selector);
        expected.activeRawShares += raw;
        expected.totalOwnershipUnits += units;
        expected.requestedRawShares = otherRaw;
        cancelAndAssert(alice, id, units, expected);
    }

    function test_minimumRequestCanCancelWithoutTransfer() public {
        uint256 ownerUnits = deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        uint256 other = request(bob, 2 ether * G);
        uint256 supply = token.totalSupply() * 2;
        vm.deal(address(overseer), supply);
        token.syncSupply(supply, 0);
        uint256 id = request(alice, G);
        assertEq(token.sharesToBalance(G), 2);
        assertEq(she.getWithdrawalRequest(id).rawShares, G);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(18 ether * G - G, 18 ether * G - G, 2 ether * G + G, 0))
        );
        (uint256 aliceUnits,,) = she.account(alice);
        (uint256 bobUnits,,) = she.account(bob);
        assertEq(aliceUnits, ownerUnits - G);
        assertEq(aliceUnits + bobUnits + SEED, storedAccounting().totalOwnershipUnits);
        backed();
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        (bool eligible, uint256 amount) = lens.previewExecution(she, id);
        assertTrue(eligible);
        assertEq(amount, 1);
        rejectCancel(alice, id, G + 1, I.StakedHypeEscrow__MinimumNotMet.selector);
        cancelAndAssert(alice, id, G, I.Accounting(18 ether * G, 18 ether * G, 2 ether * G, 0));
        (uint256 restoredUnits,,) = she.account(alice);
        assertEq(restoredUnits, ownerUnits);
        rejectCancel(alice, id, 0, I.StakedHypeEscrow__InvalidRequest.selector);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
        executeAndAssertPayout(bob, other, 2 ether);
    }

    struct CancellationScenario {
        uint256 amount;
        uint256 reward;
        uint256 removed;
        uint256 id;
        uint256 raw;
        uint256 emission;
        uint256 active;
        uint256 totalUnits;
        uint256 units;
    }

    function testFuzz_cancellationConservesSharesAndCannotIncreaseTheReturnedClaim(
        uint64 amountSeed,
        uint64 rewardSeed,
        uint32 timeSeed,
        uint16 fractionSeed
    ) public {
        CancellationScenario memory s;
        s.amount = bound(uint256(amountSeed), 1 ether, 10 ether);
        s.reward = bound(uint256(rewardSeed), 1, 2 ether);
        uint256 aliceUnits = deposit(alice, s.amount);
        deposit(bob, s.amount);
        s.removed = aliceUnits * bound(uint256(fractionSeed), 1000, 9000) / 10_000;
        s.id = request(alice, s.removed);
        s.raw = s.removed; // Both deposits and this request use the initial one-raw-share unit price.
        fund(s.reward);
        uint256 elapsed = bound(uint256(timeSeed), 0, 100);
        vm.warp(block.timestamp + elapsed);
        s.emission = s.reward * G * elapsed / 100;
        s.active = 2 * s.amount * G - s.raw + s.emission;
        s.totalUnits = 2 * s.amount * G - s.removed;
        s.units = s.raw * s.totalUnits / s.active;
        assertLe(s.units, s.removed, "cancellation recovered excluded premiums");
        cancelAndAssert(
            alice, s.id, s.units, I.Accounting(s.active + s.raw, s.totalUnits + s.units, 0, s.reward * G - s.emission)
        );
        uint256 entitlement = s.units * (s.active + s.raw) / (s.totalUnits + s.units);
        assertLe(entitlement, s.raw, "cancel/request cycle created a larger claim");
        assertGe((s.active + s.raw) * s.totalUnits, s.active * (s.totalUnits + s.units), "incumbent unit price fell");
        assertLt(s.raw * s.totalUnits - s.units * s.active, s.active, "unit rounding exceeded its floor bound");
        uint256 next = request(alice, s.units);
        assertEq(she.getWithdrawalRequest(next).rawShares, entitlement);
        executeAndAssertPayout(alice, next, entitlement / G);
    }
}
