// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";
import {stdError} from "forge-std/StdError.sol";

contract SheDepositTest is SheAssertions {
    function test_walletAndAllowanceNeedOnlyCoverActualCharge() public {
        uint256 units = deposit(alice, 2);
        uint256 id = request(alice, units - 1);
        donate(100 * (SEED + 1));
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        uint256 active = (100 * 1e6 + 1) * (SEED + 1);
        assertEq(storedAccounting().activeRawShares, SEED + 1);
        assertEq(she.totalAccounting().activeRawShares, active);
        assertEq(storedAccounting().totalOwnershipUnits, SEED + 1);
        overseer.mint{value: 101}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 100);
        {
            bytes32 beforeQuote = snapshot();
            (uint256 quoted, uint256 charge, uint256 unspentLimit) = lens.previewDeposit(she, 199);
            assertEq(quoted, 1);
            assertEq(charge, 101);
            assertEq(unspentLimit, 98); // Unspent part of the offered limit; the wallet itself contains only 101.
            assertEq(snapshot(), beforeQuote);
        }
        assertEq(wrapper.balanceOf(bob), 101);
        reject(bob, 0, abi.encodeCall(I.deposit, (199, bob, 1, 101)), stdError.arithmeticError);
        vm.prank(bob);
        wrapper.approve(address(she), 101);
        {
            uint256 held = token.sharesOf(address(she));
            uint256 totalShares = token.totalShares();
            uint256 supply = token.totalSupply();
            vm.expectCall(address(wrapper), abi.encodeCall(wstHYPE.transferFrom, (bob, address(she), 101)), uint64(1));
            vm.expectEmit(address(she));
            emitExpectedDeposited(bob, bob, 101, 1);
            vm.prank(bob);
            (uint256 issued, uint256 charge) = she.deposit(199, bob, 1, 101);
            assertEq(issued, 1);
            assertEq(charge, 101);
            assertEq(token.sharesOf(address(she)), held + 101 * 1e6);
            assertEq(token.totalShares(), totalShares);
            assertEq(token.totalSupply(), supply);
        }
        assertEq(wrapper.balanceOf(bob), 0);
        assertEq(wrapper.allowance(bob, address(she)), 0);
        assertEq(
            abi.encode(storedAccounting()), abi.encode(I.Accounting(active + 101 * 1e6, SEED + 2, 2e6 - SEED - 1, 0))
        );
        (uint256 aliceUnits,,) = she.account(alice);
        (uint256 bobUnits, uint256 raw, uint256 wrapped) = she.account(bob);
        assertEq(aliceUnits, 1);
        assertEq(bobUnits, 1);
        assertEq(raw, (active + 101 * 1e6) / (SEED + 2));
        assertEq(wrapped, raw / 1e6);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);
        assertEq(alice.balance, 0);
        assertEq(bob.balance, 0);
        assertFalse(she.isLocked());
        backed();
    }

    function test_payerRestrictionsAndInsufficientSharesRollbackCheckpointAndAllowance() public {
        deposit(alice, 10 ether);
        uint256 id = request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(1025);
        donate(1 ether);
        overseer.mint{value: 1 ether - 1}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 1 ether);
        assertEq(storedAccounting().activeRawShares, 8 ether * 1e6);
        assertEq(she.totalAccounting().activeRawShares, 10 ether * 1e6);
        assertEq(wrapper.balanceOf(bob), 1 ether - 1);
        // The allowance is debited before the real share transfer fails; both it and the checkpoint must roll back.
        reject(bob, 0, abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)), stdError.arithmeticError);
        overseer.mint{value: 1}(bob);
        vm.prank(bob);
        wrapper.setSelfDisableTransfer(true);
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)),
            abi.encodeWithSelector(wstHYPE.SelfDisableTransfer.selector)
        );
        assertTrue(wrapper.selfDisableTransfer(bob));
        vm.prank(bob);
        wrapper.setSelfDisableTransfer(false);
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        uint256 held = token.sharesOf(address(she));
        uint256 supply = token.totalSupply();
        uint256 totalShares = token.totalShares();
        vm.prank(bob);
        (uint256 units, uint256 accepted) = she.deposit(1 ether, bob, 0.8 ether * 1e6, 1 ether);
        assertEq(units, 0.8 ether * 1e6);
        assertEq(accepted, 1 ether);
        assertEq(wrapper.balanceOf(bob), 0);
        assertEq(wrapper.allowance(bob, address(she)), 0);
        assertEq(token.sharesOf(address(she)), held + 1 ether * 1e6);
        assertEq(token.totalSupply(), supply);
        assertEq(token.totalShares(), totalShares);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(11 ether * 1e6, 8.8 ether * 1e6, 2 ether * 1e6, 3 ether * 1e6))
        );
        (uint256 bobUnits, uint256 raw, uint256 wrapped) = she.account(bob);
        assertEq(bobUnits, units);
        assertEq(raw, 1 ether * 1e6);
        assertEq(wrapped, 1 ether);
        (uint256 aliceUnits,,) = she.account(alice);
        assertEq(aliceUnits, 8 ether * 1e6 - SEED);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);
        assertFalse(wrapper.selfDisableTransfer(bob));
        assertFalse(she.isLocked());
        backed();
    }

    function test_zeroDepositBeforeFirstIssuanceRejectsBeforeTransferAndPreservesState() public {
        assertEq(storedAccounting().totalOwnershipUnits, 0);
        vm.expectCall(address(wrapper), abi.encodeWithSelector(wrapper.transferFrom.selector), uint64(0));
        reject(
            alice,
            0,
            abi.encodeCall(I.deposit, (0, alice, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
        );
    }

    function test_zeroDepositRollsBackUnprocessedRewardsAndDonationBeforeTransfer() public {
        deposit(alice, 10 ether);
        request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether);
        assertEq(storedAccounting().activeRawShares, 8 ether * 1e6);
        assertEq(she.totalAccounting().activeRawShares, 10 ether * 1e6);
        vm.expectCall(address(wrapper), abi.encodeWithSelector(wrapper.transferFrom.selector), uint64(0));
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (0, alice, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
        );
    }

    function test_thirdPartyFirstDepositCreditsOnlyBeneficiaryAndBeneficiaryCanExit() public {
        overseer.mint{value: 10 ether}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 10 ether);
        uint256 expectedUnits = 10 ether * 1e6 - SEED;
        vm.expectEmit(address(she));
        emitExpectedDeposited(bob, alice, 10 ether, expectedUnits);
        vm.prank(bob);
        (uint256 units, uint256 accepted) = she.deposit(10 ether, alice, expectedUnits, 10 ether);
        assertEq(units, expectedUnits);
        assertEq(accepted, 10 ether);
        (uint256 aliceUnits, uint256 aliceRaw,) = she.account(alice);
        (uint256 bobUnits, uint256 bobRaw,) = she.account(bob);
        assertEq(aliceUnits, expectedUnits);
        assertEq(aliceRaw, expectedUnits);
        assertEq(bobUnits, 0);
        assertEq(bobRaw, 0);
        assertEq(wrapper.balanceOf(bob), 0);
        assertEq(wrapper.balanceOf(alice), 0);
        assertEq(wrapper.allowance(bob, address(she)), 0);
        assertEq(storedAccounting().activeRawShares, 10 ether * 1e6);
        assertEq(storedAccounting().totalOwnershipUnits, 10 ether * 1e6);
        reject(
            bob,
            0,
            abi.encodeCall(I.requestWithdrawal, (units, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InsufficientUnits.selector)
        );
        uint256 id = request(alice, units);
        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertEq(bob.balance, 0);
    }

    function test_thirdPartyDepositAfterRewardsPreservesExistingRequestAndPayerUnits() public {
        uint256 aliceUnits = deposit(alice, 10 ether);
        uint256 bobUnits = deposit(bob, 10 ether);
        uint256 id = request(alice, 2 ether * 1e6);
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        fund(2 ether);
        vm.warp(block.timestamp + 50);
        donate(1 ether);
        // The pre-entry pool has 18 ownership-unit tokens and 20 raw-share tokens.
        uint256 expectedUnits = uint256(1 ether * 1e6) * 18 / 20;
        overseer.mint{value: 2 ether}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 2 ether);
        uint256 held = token.sharesOf(address(she));
        vm.expectEmit(address(she));
        emitExpectedDeposited(bob, alice, 1 ether, expectedUnits);
        vm.prank(bob);
        (uint256 units, uint256 accepted) = she.deposit(1 ether, alice, expectedUnits, 1 ether);
        assertEq(units, expectedUnits);
        assertEq(accepted, 1 ether);
        (uint256 actualAlice,,) = she.account(alice);
        (uint256 actualBob,,) = she.account(bob);
        assertEq(actualAlice, aliceUnits - 2 ether * 1e6 + expectedUnits);
        assertEq(actualBob, bobUnits);
        assertEq(wrapper.balanceOf(bob), 1 ether);
        assertEq(wrapper.allowance(bob, address(she)), 1 ether);
        assertEq(token.sharesOf(address(she)), held + 1 ether * 1e6);
        assertEq(storedAccounting().activeRawShares, 21 ether * 1e6);
        assertEq(storedAccounting().totalOwnershipUnits, 18 ether * 1e6 + expectedUnits);
        assertEq(storedAccounting().requestedRawShares, 2 ether * 1e6);
        assertEq(storedAccounting().rewardRawShares, 1 ether * 1e6);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);
        executeAndAssertPayout(alice, id, 2 ether);
        assertEq(bob.balance, 0);
    }
}
