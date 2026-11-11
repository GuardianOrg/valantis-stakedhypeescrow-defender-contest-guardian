// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";

contract SheSplitActionsTest is SheAssertions {
    bytes32 private protocolBefore;

    function testFuzz_splitDepositsRespectEachEntryRoundingBound(uint32 firstSeed, uint32 secondSeed, uint8 rateSeed)
        public
    {
        prepareCoarsePool(bound(uint256(rateSeed), 1, 100));
        compareDeposits(bound(uint256(firstSeed), 101, 10_000), bound(uint256(secondSeed), 101, 10_000));
    }

    function test_splitDepositsNeedNotHaveEqualAggregateChargeOrUnits() public {
        prepareCoarsePool(100);
        (uint256 singleUnits, uint256 singleCharge, uint256 splitUnits, uint256 splitCharge) = compareDeposits(199, 199);
        assertEq(singleUnits, 3);
        assertEq(singleCharge, 301);
        assertEq(splitUnits, 2);
        assertEq(splitCharge, 202);
    }

    function prepareCoarsePool(uint256 rate) private {
        uint256 units = deposit(alice, 2);
        request(alice, units - 1);
        donate(rate * (SEED + 1));
        she.checkpointRewards();
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting((rate * 1e6 + 1) * (SEED + 1), SEED + 1, 2e6 - SEED - 1, 0))
        );
        overseer.mint{value: 20_000}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 20_000);
    }

    function compareDeposits(uint256 first, uint256 second)
        private
        returns (uint256 singleUnits, uint256 singleCharge, uint256 splitUnits, uint256 splitCharge)
    {
        bytes memory original = abi.encode(she.getWithdrawalRequest(1));
        uint256 initialAssets = storedAccounting().activeRawShares;
        uint256 branch = vm.snapshot();
        (singleUnits, singleCharge) = assertEntry(first + second);
        assertEq(storedAccounting().activeRawShares, initialAssets + singleCharge * 1e6);
        assertEq(storedAccounting().totalOwnershipUnits, SEED + 1 + singleUnits);
        assertEq(wrapper.balanceOf(bob), 20_000 - singleCharge);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), original);
        assertTrue(vm.revertTo(branch));
        (splitUnits, splitCharge) = assertEntry(first);
        (uint256 nextUnits, uint256 nextCharge) = assertEntry(second);
        splitUnits += nextUnits;
        splitCharge += nextCharge;
        assertEq(storedAccounting().activeRawShares, initialAssets + splitCharge * 1e6);
        assertEq(storedAccounting().totalOwnershipUnits, SEED + 1 + splitUnits);
        assertEq(wrapper.balanceOf(bob), 20_000 - splitCharge);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), original);
        assertEq(storedAccounting().requestedRawShares, 2e6 - SEED - 1);
        assertEq(storedAccounting().rewardRawShares, 0);
        backed();
    }

    function assertEntry(uint256 offered) private returns (uint256 units, uint256 charge) {
        I.Accounting memory before = storedAccounting();
        uint256 expectedUnits = offered * 1e6 * before.totalOwnershipUnits / before.activeRawShares;
        // One ceiling in token units, independent of quoteEntry's intermediate raw-share rounding.
        uint256 denominator = 1e6 * before.totalOwnershipUnits;
        uint256 expectedCharge = (expectedUnits * before.activeRawShares + denominator - 1) / denominator;
        (uint256 ownerUnits,,) = she.account(bob);
        uint256 balance = wrapper.balanceOf(bob);
        uint256 allowance = wrapper.allowance(bob, address(she));
        uint256 custody = token.sharesOf(address(she));
        uint256 supply = token.totalSupply();
        uint256 shares = token.totalShares();
        assertGt(expectedUnits, 0);
        assertLe(expectedCharge, offered);
        vm.expectEmit(address(she));
        emitExpectedDeposited(bob, bob, expectedCharge, expectedUnits);
        vm.prank(bob);
        (units, charge) = she.deposit(offered, bob, expectedUnits, expectedCharge);
        assertEq(units, expectedUnits);
        assertEq(charge, expectedCharge);
        // Incumbents' aggregate gain = (chargeRaw * U - units * A) / (U + units), strictly below 1e6 raw shares.
        uint256 surplusNumerator = charge * 1e6 * before.totalOwnershipUnits - units * before.activeRawShares;
        assertLt(surplusNumerator, 1e6 * (before.totalOwnershipUnits + units));
        assertEq(wrapper.balanceOf(bob), balance - charge);
        assertEq(wrapper.allowance(bob, address(she)), allowance - charge);
        assertEq(token.sharesOf(address(she)), custody + charge * 1e6);
        assertEq(token.totalSupply(), supply);
        assertEq(token.totalShares(), shares);
        (uint256 ownerAfter,,) = she.account(bob);
        assertEq(ownerAfter, ownerUnits + units);
        before.activeRawShares += charge * 1e6;
        before.totalOwnershipUnits += units;
        assertEq(abi.encode(storedAccounting()), abi.encode(before));
        assertFalse(she.isLocked());
        backed();
    }

    function testFuzz_twoRequestsReserveAtMostOneRawShareLessThanSingleRequest(
        uint80 firstSeed,
        uint80 secondSeed,
        uint64 donationSeed
    ) public {
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        request(bob, 1 ether * 1e6);
        donate(bound(uint256(donationSeed), 1, 10 ether));
        she.checkpointRewards();
        uint256 first = bound(uint256(firstSeed), 1e6, 1 ether * 1e6);
        uint256 second = bound(uint256(secondSeed), 1e6, 1 ether * 1e6);
        I.Accounting memory initial = storedAccounting();
        protocolBefore = protocolState();
        bytes memory other = abi.encode(she.getWithdrawalRequest(1));
        uint256 custody = token.sharesOf(address(she));
        uint256 branch = vm.snapshot();
        uint256 singleId = request(alice, first + second);
        uint256 singleRaw = she.getWithdrawalRequest(singleId).rawShares;
        assertEq(singleRaw, (first + second) * initial.activeRawShares / initial.totalOwnershipUnits);
        assertRequest(singleId, singleRaw);
        assertAccountingAfterRequests(initial, first + second, singleRaw, custody);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), other);
        assertTrue(vm.revertTo(branch));
        uint256 firstId = request(alice, first);
        uint256 firstRaw = first * initial.activeRawShares / initial.totalOwnershipUnits;
        assertRequest(firstId, firstRaw);
        bytes memory firstRequest = abi.encode(she.getWithdrawalRequest(firstId));
        uint256 secondId = request(alice, second);
        uint256 secondRaw = second * (initial.activeRawShares - firstRaw) / (initial.totalOwnershipUnits - first);
        assertRequest(secondId, secondRaw);
        assertEq(firstId, singleId);
        assertEq(secondId, firstId + 1);
        assertEq(abi.encode(she.getWithdrawalRequest(firstId)), firstRequest);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), other);
        assertLe(firstRaw + secondRaw, singleRaw);
        assertLe(singleRaw - firstRaw - secondRaw, 1);
        assertAccountingAfterRequests(initial, first + second, firstRaw + secondRaw, custody);
    }

    function assertRequest(uint256 id, uint256 raw) private view {
        assertEq(
            abi.encode(she.getWithdrawalRequest(id)),
            abi.encode(
                I.WithdrawalRequest(
                    alice, raw, uint64(block.timestamp), uint64(block.timestamp + 10), I.RequestStatus.REQUESTED
                )
            )
        );
    }

    function assertAccountingAfterRequests(I.Accounting memory initial, uint256 units, uint256 raw, uint256 custody)
        private
        view
    {
        // Keep the shared branch baseline immutable: vm.revertTo restores EVM state, not this memory object.
        I.Accounting memory expected = I.Accounting(
            initial.activeRawShares - raw,
            initial.totalOwnershipUnits - units,
            initial.requestedRawShares + raw,
            initial.rewardRawShares
        );
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        (uint256 remaining,,) = she.account(alice);
        assertEq(remaining, 10 ether * 1e6 - SEED - units);
        assertEq(token.sharesOf(address(she)), custody);
        assertEq(protocolState(), protocolBefore);
        assertEq(alice.balance, 0);
        assertFalse(she.isLocked());
        backed();
    }

    function protocolState() private view returns (bytes32) {
        // The real initialize/initializeV3 fixture already contains two completed zero-amount sentinel burns.
        return keccak256(
            abi.encode(
                token.totalShares(),
                token.totalSupply(),
                overseer.getAllBurns(),
                overseer.redeemed(),
                overseer.totalPendingBurns(),
                address(overseer).balance
            )
        );
    }
}
