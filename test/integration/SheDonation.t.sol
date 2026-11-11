// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";

// Actual protocol proxies, with no injected SHE balances or ownership units.
// Payout bounds use a constant upstream rate, except for the explicit rebased-token donation test.
contract SheDonationTest is SheAssertions {
    uint256 constant G = 1e6;

    struct Attempt {
        uint256 active;
        uint256 issued;
        uint256 charged;
        uint256 totalActive;
        uint256 seedRequest;
        uint256 aliceRequest;
        uint256 bobRequest;
        uint256 aliceClaim;
        uint256 bobClaim;
        uint256 seedClaim;
    }

    function assertLedger(uint256 active, uint256 units, uint256 queued, uint256 reserve, uint256 surplus)
        internal
        view
    {
        // Read persisted buckets directly: totalAccounting() would silently incorporate surplus.
        I.Accounting memory a = storedAccounting();
        assertEq(a.activeRawShares, active, "stored active");
        assertEq(a.totalOwnershipUnits, units, "stored units");
        assertEq(a.requestedRawShares, queued, "stored requests");
        assertEq(a.rewardRawShares, reserve, "stored reserve");
        assertEq(token.sharesOf(address(she)), active + queued + reserve + surplus, "actual custody");
        (uint256 au,,) = she.account(alice);
        (uint256 bu,,) = she.account(bob);
        (uint256 seedUnits,,) = she.account(address(1));
        assertEq(seedUnits, units == 0 ? 0 : SEED);
        assertEq(au + bu + seedUnits, units, "independent owners");
        assertFalse(she.isLocked());
    }

    function seedSmallPool(uint256 units) internal returns (uint256 id) {
        uint256 initial = deposit(alice, 2);
        id = request(alice, initial - units);
        assertEq(she.getWithdrawalRequest(id).rawShares, 2 * G - SEED - units);
        assertLedger(SEED + units, SEED + units, 2 * G - SEED - units, 0, 0);
    }

    function donateFromAlice(uint256 amount) internal {
        vm.deal(address(this), address(this).balance + amount);
        overseer.mint{value: amount}(alice);
        vm.prank(alice);
        assertTrue(wrapper.transfer(address(she), amount));
        assertEq(wrapper.balanceOf(alice), 0);
    }

    function prepareBob(uint256 amount) internal {
        overseer.mint{value: amount}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), amount);
    }

    function test_seedOnlyPoolDonationsCannotBeCapturedByRepeatedRefills() public {
        uint256 reserve = (7 ether + 1) * G;
        donate(7 ether + 1);
        assertLedger(0, 0, 0, 0, reserve);
        for (uint256 i; i < 3; ++i) {
            address owner = i % 2 == 0 ? alice : bob;
            uint256 units = deposit(owner, i == 0 ? 2 : 1);
            uint256 expected = i == 0 ? 2 * G - SEED : G;
            assertEq(units, expected);
            assertLedger(SEED + expected, SEED + expected, 0, reserve, 0);
            uint256 id = request(owner, units);
            assertEq(she.getWithdrawalRequest(id).rawShares, expected);
            assertLedger(SEED, SEED, expected, reserve, 0);
            executeAndAssertPayout(owner, id, 1);
            reserve += expected - G;
            assertLedger(SEED, SEED, 0, reserve, 0);
        }
        assertEq(wrapper.balanceOf(alice), 2);
        assertEq(wrapper.balanceOf(bob), 1);
    }

    function test_seedOnlyRefillSeparatesDonationsPendingClaimsAndElapsedRewards() public {
        uint256 aliceId = request(alice, deposit(alice, 10 ether));
        fund(10 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 50);
        donate(7 ether);
        assertLedger(SEED, SEED, 10 ether * G - SEED, 10 ether * G, 7 ether * G);
        uint256 bobUnits = deposit(bob, 1 ether);
        assertEq(bobUnits, 1 ether * G);
        assertLedger(1 ether * G + SEED, bobUnits + SEED, 10 ether * G - SEED, 17 ether * G, 0);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(stream.releasedRawShares, 5 ether * G);
        assertEq(retained, 12 ether * G);
        vm.warp(start + 100);
        she.checkpointRewards();
        assertLedger(6 ether * G + SEED, bobUnits + SEED, 10 ether * G - SEED, 12 ether * G, 0);
        executeAndAssertPayout(alice, aliceId, 10 ether - 1);
        uint256 pool = 6 ether * G + G;
        uint256 bobRaw = bobUnits * pool / (bobUnits + SEED);
        uint256 bobId = request(bob, bobUnits);
        assertEq(she.getWithdrawalRequest(bobId).rawShares, bobRaw);
        executeAndAssertPayout(bob, bobId, bobRaw / G);
        uint256 seedAssets = pool - bobRaw;
        retained = 12 ether * G + bobRaw % G;
        assertLedger(seedAssets, SEED, 0, retained, 0);
        uint256 fresh = deposit(alice, 1);
        assertEq(fresh, G * SEED / seedAssets);
        assertLedger(seedAssets + G, SEED + fresh, 0, retained, 0);
        fund(1);
        vm.warp(block.timestamp + 100);
        she.checkpointRewards();
        pool = seedAssets + 2 * G + retained;
        assertLedger(pool, SEED + fresh, 0, 0, 0);
        uint256 raw = fresh * pool / (SEED + fresh);
        uint256 id = request(alice, fresh);
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        executeAndAssertPayout(alice, id, raw / G);
        assertLedger(pool - raw, SEED, 0, raw % G, 0);
    }

    function test_donationPricesOutSmallOffersAtSubstantialPermanentCost() public {
        uint256 seedId = seedSmallPool(1);
        prepareBob(99 ether);
        donateFromAlice(100 ether * (SEED + 1));
        uint256 donated = 100 ether * (SEED + 1) * G;
        assertLedger(SEED + 1, SEED + 1, 2 * G - SEED - 1, 0, donated);
        (uint256 units, uint256 accepted, uint256 unspent) = lens.previewDeposit(she, 99 ether);
        assertEq(units, 0);
        assertEq(accepted, 0);
        assertEq(unspent, 99 ether);
        bytes memory invalid = abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector);
        reject(bob, 0, abi.encodeCall(I.deposit, (99 ether, bob, 0, 0)), invalid);
        uint256 aliceId = request(alice, 1);
        executeAndAssertPayout(alice, seedId, 1);
        executeAndAssertPayout(alice, aliceId, 100 ether);
        uint256 seedAssets = (100 ether * G + 1) * SEED;
        assertLedger(seedAssets, SEED, 0, G - SEED, 0);
        assertEq(wrapper.balanceOf(alice), 100 ether + 1);
        assertGt(seedAssets, 100_000 ether * G); // Most of the donor's 100,100 wstHYPE is unrecoverable.
        // Unlike the previous unseeded design, the pool retains its price after the last user exits.
        reject(bob, 0, abi.encodeCall(I.deposit, (99 ether, bob, 0, 0)), invalid);
        overseer.mint{value: 100 ether}(bob);
        vm.startPrank(bob);
        wrapper.approve(address(she), 199 ether);
        (units, accepted) = she.deposit(199 ether, bob, 1, 100 ether + 1);
        vm.stopPrank();
        assertEq(units, 1);
        assertEq(accepted, 100 ether + 1);
        assertEq(wrapper.balanceOf(bob), 99 ether - 1);
        assertLedger(seedAssets + accepted * G, SEED + 1, 0, G - SEED, 0);
    }

    function test_donationInvalidatesBothDepositMinimaWithCompleteRollback() public {
        seedSmallPool(1);
        prepareBob(199 ether);
        (uint256 priorUnits, uint256 priorCharge,) = lens.previewDeposit(she, 199 ether);
        assertEq(priorUnits, 199 ether * G);
        assertEq(priorCharge, 199 ether);
        donateFromAlice(100 ether * (SEED + 1));
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (199 ether, bob, priorUnits, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (199 ether, bob, 0, priorCharge)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        assertLedger(SEED + 1, SEED + 1, 2 * G - SEED - 1, 0, 100 ether * G * (SEED + 1));
    }

    function test_oneUnitDonationRoundTripAttackerRequestsFirst() public {
        assertDonationRoundTrip(1, 100 ether * (SEED + 1), 199 ether, true);
    }

    function test_oneUnitDonationRoundTripVictimRequestsFirst() public {
        assertDonationRoundTrip(1, 100 ether * (SEED + 1), 199 ether, false);
    }

    function testFuzz_smallUnitDonationBoundsVictimLossThroughPayout(
        uint8 unitSeed,
        uint96 donationSeed,
        uint96 offerSeed,
        bool attackerFirst
    ) public {
        uint256 units = bound(uint256(unitSeed), 1, 32);
        uint256 donation = bound(uint256(donationSeed), SEED + 1, 100 ether);
        uint256 minimum = (donation * G + SEED + units + G * (SEED + units) - 1) / (G * (SEED + units));
        if (minimum < 2) minimum = 2; // Ensure a representable withdrawal of at least one HYPE wei.
        uint256 offered = bound(uint256(offerSeed), minimum, 3 * (donation + 1));
        assertDonationRoundTrip(units, donation, offered, attackerFirst);
    }

    function assertDonationRoundTrip(uint256 units, uint256 donation, uint256 offered, bool attackerFirst) internal {
        Attempt memory t;
        t.seedRequest = seedSmallPool(units);
        prepareBob(offered);
        donateFromAlice(donation);
        t.active = SEED + units + donation * G;
        t.issued = offered * G * (SEED + units) / t.active;
        // Independent integer entitlement inequality; no expected amount comes from SHE or Lens.
        t.charged = (t.issued * t.active + (SEED + units) * G - 1) / ((SEED + units) * G);
        assertGt(t.issued, 0);
        assertLedger(SEED + units, SEED + units, 2 * G - SEED - units, 0, donation * G);
        {
            (uint256 quoted, uint256 charge, uint256 unspent) = lens.previewDeposit(she, offered);
            assertEq(quoted, t.issued);
            assertEq(charge, t.charged);
            assertEq(unspent, offered - t.charged);
            vm.prank(bob);
            (uint256 issued, uint256 accepted) = she.deposit(offered, bob, 0, 0);
            assertEq(issued, t.issued);
            assertEq(accepted, t.charged);
        }
        assertEq(wrapper.balanceOf(bob), offered - t.charged);
        assertEq(wrapper.allowance(bob, address(she)), offered - t.charged);
        assertGe(t.charged * G * (SEED + units), t.issued * t.active);
        assertLt(t.charged * G * (SEED + units) - t.issued * t.active, G * (SEED + units));
        assertLt((t.charged - 1) * G * (SEED + units), t.issued * t.active);
        t.totalActive = t.active + t.charged * G;
        assertLedger(t.totalActive, SEED + units + t.issued, 2 * G - SEED - units, 0, 0);
        if (attackerFirst) {
            t.aliceClaim = units * t.totalActive / (SEED + units + t.issued);
            t.bobClaim = t.issued * (t.totalActive - t.aliceClaim) / (SEED + t.issued);
            t.aliceRequest = request(alice, units);
            t.bobRequest = request(bob, t.issued);
        } else {
            t.bobClaim = t.issued * t.totalActive / (SEED + units + t.issued);
            t.aliceClaim = units * (t.totalActive - t.bobClaim) / (SEED + units);
            t.bobRequest = request(bob, t.issued);
            t.aliceRequest = request(alice, units);
        }
        assertEq(she.getWithdrawalRequest(t.aliceRequest).rawShares, t.aliceClaim);
        assertEq(she.getWithdrawalRequest(t.bobRequest).rawShares, t.bobClaim);
        assertEq(she.getWithdrawalRequest(t.seedRequest).rawShares, 2 * G - SEED - units);
        assertLe(t.charged * G - t.bobClaim, G);
        uint256 totalIn = (2 + donation + t.charged) * G;
        t.seedClaim = t.totalActive - t.aliceClaim - t.bobClaim;
        assertGe(t.seedClaim, SEED * t.active / (SEED + units));
        assertLedger(t.seedClaim, SEED, totalIn - t.seedClaim, 0, 0);
        executeAndAssertPayout(alice, t.seedRequest, 1);
        executeAndAssertPayout(alice, t.aliceRequest, t.aliceClaim / G);
        executeAndAssertPayout(bob, t.bobRequest, t.bobClaim / G);
        assertEq(wrapper.balanceOf(bob), offered - t.charged + t.bobClaim / G);
        // The wallet contains both the unspent offer and the returned wstHYPE.
        assertLe(offered - wrapper.balanceOf(bob), 1);
        assertLe(wrapper.balanceOf(alice), 2 + donation + 1);
        assertEq(wrapper.balanceOf(alice), 1 + t.aliceClaim / G);
        uint256 dust = totalIn - t.seedClaim - (1 + t.aliceClaim / G + t.bobClaim / G) * G;
        assertLt(dust, 3 * G);
        assertLedger(t.seedClaim, SEED, 0, dust, 0);
    }

    function test_repeatedVictimsAccumulateOnlyPerDepositWeiRounding() public {
        uint256 seedId = seedSmallPool(1);
        donateFromAlice(100 * (SEED + 1));
        uint256 count = 8;
        prepareBob(count * 199);
        uint256 pool = (SEED + 1) * (100 * G + 1);
        for (uint256 i; i < count; ++i) {
            uint256 expectedUnits = 199 * G * (SEED + 1) / pool;
            uint256 expectedCharge = (expectedUnits * pool + (SEED + 1) * G - 1) / ((SEED + 1) * G);
            vm.prank(bob);
            (uint256 issued, uint256 charged) = she.deposit(199, bob, 0, 0);
            assertEq(issued, expectedUnits);
            assertEq(charged, expectedCharge);
            uint256 raw = issued * (pool + charged * G) / (SEED + 1 + issued);
            uint256 id = request(bob, issued);
            assertEq(she.getWithdrawalRequest(id).rawShares, raw);
            executeAndAssertPayout(bob, id, raw / G);
            assertEq(count * 199 - wrapper.balanceOf(bob), i + 1);
            pool += charged * G - raw / G * G;
            assertLedger(pool, SEED + 1, 2 * G - SEED - 1, 0, 0);
        }
        uint256 aliceRaw = pool / (SEED + 1);
        uint256 aliceId = request(alice, 1);
        assertEq(she.getWithdrawalRequest(aliceId).rawShares, aliceRaw);
        executeAndAssertPayout(alice, seedId, 1);
        executeAndAssertPayout(alice, aliceId, aliceRaw / G);
        assertEq(wrapper.balanceOf(alice), aliceRaw / G + 1);
        assertLt(wrapper.balanceOf(alice), 2 + 100 * (SEED + 1));
        assertEq(count * 199 - wrapper.balanceOf(bob), count);
        assertLedger(pool - aliceRaw, SEED, 0, G - SEED - 1 + aliceRaw % G, 0);
    }

    function test_rebasedStHypeDonationsBelowWrappedWeiAreAccountedBeforeEntry() public {
        overseer.mint{value: 1 ether}(alice);
        overseer.mint{value: 1 ether}(bob);
        // Backed local upstream-rate fixture. The donation itself uses the public stHYPE transfer API.
        uint256 supply = token.totalSupply();
        vm.deal(address(overseer), supply * 2);
        token.syncSupply(supply * 2, 20);
        vm.warp(token.syncEnd() + 1);
        assertEq(token.balanceToShares(1), G / 2);
        vm.prank(alice);
        assertTrue(token.transfer(address(she), 1));
        assertEq(wrapper.balanceOf(address(she)), 0);
        assertLedger(0, 0, 0, 0, G / 2);
        vm.startPrank(bob);
        wrapper.approve(address(she), 2);
        (uint256 issued, uint256 charged) = she.deposit(2, bob, 2 * G - SEED, 2);
        vm.stopPrank();
        assertEq(issued, 2 * G - SEED);
        assertEq(charged, 2);
        assertLedger(2 * G, 2 * G, 0, G / 2, 0);
        vm.prank(alice);
        assertTrue(token.transfer(address(she), 1));
        assertLedger(2 * G, 2 * G, 0, G / 2, G / 2);
        uint256 beforeShares = token.sharesOf(alice);
        vm.startPrank(alice);
        wrapper.approve(address(she), 2);
        (issued, charged) = she.deposit(2, alice, 1_600_000, 2);
        vm.stopPrank();
        assertEq(issued, 1_600_000);
        assertEq(charged, 2);
        assertEq(token.sharesOf(alice), beforeShares - 2 * G);
        assertLedger(9 * G / 2, 2 * G + 1_600_000, 0, G / 2, 0);
        (, uint256 bobShares,) = she.account(bob);
        (, uint256 aliceShares,) = she.account(alice);
        assertEq(bobShares, (2 * G - SEED) * (9 * G / 2) / (2 * G + 1_600_000));
        assertEq(aliceShares, 2 * G);
    }
}
