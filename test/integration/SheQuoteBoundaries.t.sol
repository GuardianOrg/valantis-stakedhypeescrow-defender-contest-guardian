// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stdError} from "forge-std/StdError.sol";

contract SheQuoteBoundariesTest is SheAssertions {
    function testFuzz_quoteUsesFullPrecisionWhenBothProductsExceedUint256(uint192 offerSeed, uint8 rateSeed)
        public
        view
    {
        // Synthetic valid quote totals, not a claim that these raw-share quantities exist in production.
        // Algebraic construction gives an independent oracle without reusing Math.mulDiv.
        uint256 offered = bound(uint256(offerSeed), 1 << 160, type(uint192).max);
        offered = offered / 1e6 * 1e6;
        uint256 rate = bound(uint256(rateSeed), 2, 255);
        uint256 totalUnits = 1 << 128;
        uint256 active = totalUnits * rate;
        uint256 expectedUnits = offered / rate;
        uint256 expectedCharge = (expectedUnits * rate + 1e6 - 1) / 1e6 * 1e6;
        assertGt(offered, type(uint256).max / totalUnits);
        assertGt(expectedUnits, type(uint256).max / active);
        (uint256 units, uint256 charge) = she.quoteEntry(offered, active, totalUnits);
        assertEq(units, expectedUnits);
        assertEq(charge, expectedCharge);
        assertLe(charge, offered);
        assertEq(charge % 1e6, 0);
        assertGe(charge, units * rate);
        assertLt(charge - units * rate, 1e6);
        assertLt(charge - 1e6, units * rate);
    }

    function test_quoteEntryRejectsInconsistentPoolTotalsAndSeparatesInitialNominalMinimum() public {
        bytes32 before = snapshot();
        vm.expectRevert(I.StakedHypeEscrow__AccountingInvariant.selector);
        she.quoteEntry(2e6, 1, 0);
        vm.expectRevert(I.StakedHypeEscrow__AccountingInvariant.selector);
        she.quoteEntry(2e6, 0, SEED);
        (uint256 units, uint256 charged) = she.quoteEntry(0, 0, 0);
        assertEq(units, 0);
        assertEq(charged, 0);
        (units, charged) = she.quoteEntry(1e6, 0, 0);
        assertEq(units, 1e6 - SEED);
        assertEq(charged, 1e6);
        (uint256 quoted, uint256 accepted, uint256 unspent) = lens.previewDeposit(she, 1);
        assertEq(quoted, 0);
        assertEq(accepted, 0);
        assertEq(unspent, 1);
        assertEq(snapshot(), before);
    }

    function test_wrappedAmountOverflowRollsBackUnprocessedRewardsAndDonation() public {
        deposit(alice, 10 ether);
        request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether);
        uint256 maxWrapped = type(uint256).max / 1e6;
        bytes32 before = snapshot();
        vm.expectRevert(stdError.arithmeticError);
        lens.previewDeposit(she, maxWrapped + 1);
        assertEq(snapshot(), before);
        reject(bob, 0, abi.encodeCall(I.deposit, (maxWrapped + 1, bob, 0, 0)), stdError.arithmeticError);
        // The largest representable offer must still quote using full precision; no wallet is funded with it.
        (uint256 units, uint256 charge, uint256 unspent) = lens.previewDeposit(she, maxWrapped);
        uint256 raw = maxWrapped * 1e6;
        // Active rate is 10/8: use quotient/remainder decomposition to avoid overflowing the oracle.
        uint256 expectedUnits = raw / 5 * 4 + raw % 5 * 4 / 5;
        assertEq(units, expectedUnits);
        assertEq(charge, maxWrapped);
        assertEq(unspent, 0);
        assertEq(snapshot(), before);
    }
}
