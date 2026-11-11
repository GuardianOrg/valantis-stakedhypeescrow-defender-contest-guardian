// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";

contract SheSeedTest is SheAssertions {
    uint256 constant G = 1e6;

    function assertSeed(uint256 totalUnits, uint256 active) internal view {
        I.Accounting memory stored = storedAccounting();
        assertEq(stored.totalOwnershipUnits, totalUnits);
        assertEq(stored.activeRawShares, active);
        (uint256 units, uint256 raw,) = she.account(address(1));
        assertEq(units, SEED);
        assertEq(raw, SEED * active / totalUnits);
        assertEq(token.sharesOf(address(she)), active + stored.requestedRawShares + stored.rewardRawShares);
    }

    function test_firstIssuanceMinimaAndTransferFailuresRollBackSeedAndState() public {
        assertEq(she.SEED_OWNER(), address(1));
        assertEq(she.SEED_OWNERSHIP_UNITS(), SEED);
        overseer.mint{value: 2}(alice);
        vm.prank(alice);
        wrapper.approve(address(she), 2);
        donate(5 ether);
        assertEq(storedAccounting().rewardRawShares, 0);
        (uint256 quote, uint256 charge, uint256 unspent) = lens.previewDeposit(she, 1);
        assertEq(quote, 0);
        assertEq(charge, 0);
        assertEq(unspent, 1);
        reject(
            alice,
            0,
            abi.encodeCall(I.deposit, (1, alice, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
        );
        reject(
            alice,
            0,
            abi.encodeCall(I.deposit, (2, alice, 2 * G - SEED + 1, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        reject(
            alice,
            0,
            abi.encodeCall(I.deposit, (2, alice, 0, 3)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        token.pauseTransfer(true);
        reject(
            alice,
            0,
            abi.encodeCall(I.deposit, (2, alice, 0, 0)),
            abi.encodeWithSelector(stHYPE.TransferIsPaused.selector)
        );
        token.pauseTransfer(false);
        (uint256 seed,,) = she.account(address(1));
        assertEq(seed, 0);
        assertEq(storedAccounting().totalOwnershipUnits, 0);
        (quote, charge, unspent) = lens.previewDeposit(she, 2);
        assertEq(quote, 2 * G - SEED);
        assertEq(charge, 2);
        assertEq(unspent, 0);
        vm.recordLogs();
        vm.prank(alice);
        (uint256 units, uint256 accepted) = she.deposit(2, alice, quote, charge);
        assertEq(units, quote);
        assertEq(accepted, 2);
        assertEq(wrapper.balanceOf(alice), 0);
        assertEq(wrapper.allowance(alice, address(she)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seeds;
        uint256 deposits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(she)) continue;
            if (logs[i].topics[0] == I.SeedLocked.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(1));
                assertEq(abi.decode(logs[i].data, (uint256)), SEED);
                ++seeds;
            }
            if (logs[i].topics[0] == I.Deposited.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
                (uint256 amount, uint256 issued) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amount, 2);
                assertEq(issued, 2 * G - SEED);
                ++deposits;
            }
        }
        assertEq(seeds, 1);
        assertEq(deposits, 1);
        assertSeed(2 * G, 2 * G);
        assertEq(storedAccounting().rewardRawShares, 5 ether * G);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(abi.encode(stream), abi.encode(I.RewardStream(0, 0, 0, 0)));
        assertEq(retained, 5 ether * G);
    }

    function test_fundingAndCheckpointRequireFirstDepositWithFullRollback() public {
        bytes memory reason = abi.encodeWithSelector(I.StakedHypeEscrow__AccountingInvariant.selector);
        for (uint256 i; i < 2; ++i) {
            if (i == 1) donate(5 ether);
            assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(0, 0, 0, 0)));
            assertEq(token.sharesOf(address(she)), i * 5 ether * G);
            (uint256 seedUnits,,) = she.account(address(1));
            assertEq(seedUnits, 0);
            reject(alice, 0, abi.encodeCall(I.checkpointRewards, ()), reason);
            reject(distributor, 1 ether, abi.encodeCall(I.fundRewards, (1 ether * G)), reason);
            assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(0, 0, 0, 0)));
            assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(0, 0, 0, i * 5 ether * G)));
            (I.RewardStream memory stream, uint256 retained) = she.rewardState();
            assertEq(abi.encode(stream), abi.encode(I.RewardStream(0, 0, 0, 0)));
            assertEq(retained, i * 5 ether * G);
        }

        assertEq(deposit(alice, 2), 2 * G - SEED);
        assertSeed(2 * G, 2 * G);
        assertEq(storedAccounting().rewardRawShares, 5 ether * G);
        assertEq(storedAccounting().requestedRawShares, 0);
        (uint256 units, uint256 active, uint256 wrapped) = she.account(alice);
        assertEq(units, 2 * G - SEED);
        assertEq(active, 2 * G - SEED);
        assertEq(wrapped, 1);
        bytes32 beforeState = snapshot();
        she.checkpointRewards();
        assertEq(snapshot(), beforeState);

        uint256 supplyBefore = token.totalSupply();
        uint256 sharesBefore = token.totalShares();
        uint256 backingBefore = address(overseer).balance;
        uint256 distributorBefore = distributor.balance;
        fund(1 ether);
        assertSeed(2 * G, 2 * G);
        assertEq(storedAccounting().rewardRawShares, 6 ether * G);
        assertEq(storedAccounting().requestedRawShares, 0);
        assertEq(token.totalSupply(), supplyBefore + 1 ether);
        assertEq(token.totalShares(), sharesBefore + 1 ether * G);
        assertEq(address(overseer).balance, backingBefore + 1 ether);
        assertEq(distributor.balance, distributorBefore - 1 ether);
        assertEq(wrapper.allowance(alice, address(she)), 0);
        assertEq(wrapper.allowance(address(she), address(overseer)), 0);
        (I.RewardStream memory funded, uint256 retainedAfter) = she.rewardState();
        assertEq(
            abi.encode(funded),
            abi.encode(I.RewardStream(6 ether * G, 0, uint64(block.timestamp), uint64(block.timestamp + 100)))
        );
        assertEq(retainedAfter, 0);
        backed();
    }

    function test_seedCannotReceiveDepositsOrWithdrawAndIsNotReissuedOnRefill() public {
        bytes memory invalid = abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAddress.selector);
        reject(alice, 0, abi.encodeCall(I.deposit, (2, address(1), 0, 0)), invalid);
        uint256 units = deposit(alice, 2);
        reject(alice, 0, abi.encodeCall(I.deposit, (2, address(1), 0, 0)), invalid);
        reject(address(1), 0, abi.encodeCall(I.requestWithdrawal, (SEED, 0)), invalid);
        vm.expectRevert(invalid);
        lens.previewRequestWithdrawal(she, address(1), SEED);
        uint256 id = request(alice, units);
        assertEq(she.getWithdrawalRequest(id).rawShares, 2 * G - SEED);
        assertSeed(SEED, SEED);
        executeAndAssertPayout(alice, id, 1);
        assertEq(storedAccounting().rewardRawShares, G - SEED);
        vm.recordLogs();
        uint256 fresh = deposit(bob, 1);
        assertEq(fresh, G);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(she) && logs[i].topics[0] == I.SeedLocked.selector);
        }
        assertSeed(SEED + G, SEED + G);
        assertEq(storedAccounting().rewardRawShares, G - SEED);
    }

    function test_seedOnlyPoolRetainsEmissionsDonationsAndDustForFutureFunding() public {
        uint256 units = deposit(alice, 2 ether);
        fund(2 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 50);
        uint256 id = request(alice, units);
        uint256 raw = 3 ether * G - 1500;
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        assertSeed(SEED, 1500);
        vm.warp(start + 100);
        donate(5 ether);
        I.Accounting memory preview = she.totalAccounting();
        assertEq(preview.activeRawShares, 1500);
        assertEq(preview.rewardRawShares, 6 ether * G);
        assertEq(storedAccounting().rewardRawShares, 1 ether * G);
        she.checkpointRewards();
        assertEq(abi.encode(storedAccounting()), abi.encode(preview));
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(stream.releasedRawShares, 2 ether * G);
        assertEq(retained, 6 ether * G);
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        executeAndAssertPayout(alice, id, 3 ether - 1);
        uint256 reserve = 6 ether * G + G - 1500;
        assertSeed(SEED, 1500);
        assertEq(storedAccounting().rewardRawShares, reserve);
        uint256 fresh = deposit(bob, 3);
        assertEq(fresh, 2 * G);
        assertEq(storedAccounting().rewardRawShares, reserve);
        fund(1);
        vm.warp(block.timestamp + 100);
        she.checkpointRewards();
        assertSeed(SEED + fresh, 6 ether * G + 5 * G);
        assertEq(storedAccounting().rewardRawShares, 0);
        (, uint256 entitlement,) = she.account(bob);
        assertEq(entitlement, fresh * (6 ether * G + 5 * G) / (SEED + fresh));
    }

    function test_singleUserUnitStillEarnsAlongsideTheSeed() public {
        uint256 units = deposit(alice, 2);
        request(alice, units - 1);
        assertSeed(SEED + 1, SEED + 1);
        fund(SEED + 1);
        vm.warp(block.timestamp + 100);
        she.checkpointRewards();
        assertSeed(SEED + 1, (SEED + 1) * (G + 1));
        (uint256 userUnits, uint256 raw,) = she.account(alice);
        assertEq(userUnits, 1);
        assertEq(raw, G + 1);
        (uint256 locked, uint256 lockedRaw,) = she.account(address(1));
        assertEq(locked, SEED);
        assertEq(lockedRaw, SEED * (G + 1));
        assertEq(storedAccounting().rewardRawShares, 0);
        request(alice, 1);
        assertSeed(SEED, SEED * (G + 1));
        assertGt(token.sharesToBalance(SEED * (G + 1)), 0);
        // This seed-only position is otherwise requestable: the explicit owner guard prevents a full reset.
        reject(
            address(1),
            0,
            abi.encodeCall(I.requestWithdrawal, (SEED, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAddress.selector)
        );
    }

    function testFuzz_firstDepositMinimumUsesCurrentUpstreamRate(uint16 rateSeed) public {
        // Positive backed fixture rates from 0.1 to 3 HYPE per wstHYPE, including loss scenarios.
        uint256 rate = bound(uint256(rateSeed), 1000, 30000);
        overseer.mint{value: 1 ether}(alice);
        uint256 supply = token.totalSupply() * rate / 10000;
        vm.deal(address(overseer), supply);
        token.syncSupply(supply, 0);
        vm.prank(alice);
        wrapper.approve(address(she), 20);
        // First-user raw entitlement is amount*G-SEED; solve the one-HYPE-wei boundary independently.
        uint256 minimum = ((G * 10000 + rate - 1) / rate + SEED + G - 1) / G;
        if (minimum < 2) minimum = 2; // At least one transferable wstHYPE wei after funding the seed.
        if (minimum > 1) {
            (uint256 quoted, uint256 charge, uint256 unspent) = lens.previewDeposit(she, minimum - 1);
            assertEq(quoted, 0);
            assertEq(charge, 0);
            assertEq(unspent, minimum - 1);
            reject(
                alice,
                0,
                abi.encodeCall(I.deposit, (minimum - 1, alice, 0, 0)),
                abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
            );
        }
        (uint256 quote, uint256 accepted,) = lens.previewDeposit(she, minimum);
        assertEq(quote, minimum * G - SEED);
        assertEq(accepted, minimum);
        vm.prank(alice);
        (uint256 issued, uint256 charged) = she.deposit(minimum, alice, quote, minimum);
        assertEq(issued, quote);
        assertEq(charged, minimum);
        assertSeed(minimum * G, minimum * G);
        uint256 id = request(alice, issued);
        assertEq(she.getWithdrawalRequest(id).rawShares, minimum * G - SEED);
        assertGe(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), 1);
        assertGe(she.getWithdrawalRequest(id).rawShares, G);
        executeAndAssertPayout(alice, id, (minimum * G - SEED) / G);
    }
}
