// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";

// Real local token/Overseer proxies. Rate changes are backed token sync fixtures,
// not simulations of HyperCore losses or of production rebase authorization.
contract SheSettlementRoundingTest is SheAssertions {
    uint256 constant G = 1e6;

    struct Exit {
        I.WithdrawalRequest claim;
        I.WithdrawalRequest other;
        I.Accounting expected;
        uint256 supply;
        uint256 shares;
        uint256 held;
        uint256 amount;
        uint256 liquid;
        uint256 transferred;
        uint256 burnCountBefore;
        bytes32 rewards;
        bytes config;
    }

    function testFuzz_transferAtChangedRatesConservesEveryShare(uint16 rateSeed, uint16 liquidSeed, bool seedOnly)
        public
    {
        uint256 rate = bound(uint256(rateSeed), 5000, 20000);
        uint256 liquidBps = bound(uint256(liquidSeed), 1, 9999);
        checkExit(rate, liquidBps, 2, seedOnly);
    }

    function test_liquidityEndpointsDoNotChangeWstHypeSettlement() public {
        for (uint256 mode; mode < 6; ++mode) {
            for (uint256 empty; empty < 2; ++empty) {
                uint256 branch = vm.snapshot();
                checkExit(13333, 5000, mode, empty == 1);
                assertTrue(vm.revertTo(branch));
            }
        }
    }

    function checkExit(uint256 rate, uint256 liquidBps, uint256 mode, bool seedOnly) private {
        Exit memory e;
        uint256 aliceUnits = deposit(alice, 10 ether + 17);
        uint256 bobUnits = deposit(bob, 6 ether + 29);
        uint256 id = request(alice, seedOnly ? aliceUnits : 6 ether * G + 123);
        uint256 otherId = request(bob, seedOnly ? bobUnits : 1 ether * G + 17);
        e.claim = she.getWithdrawalRequest(id);
        e.other = she.getWithdrawalRequest(otherId);
        assertEq(id, 1);
        assertEq(otherId, 2);
        assertEq(e.claim.rawShares, seedOnly ? aliceUnits : 6 ether * G + 123);
        assertEq(e.other.rawShares, seedOnly ? bobUnits : 1 ether * G + 17);
        fund(4 ether + 7);
        vm.warp(1025);
        donate(1);

        e.shares = token.totalShares();
        e.supply = token.totalSupply() * rate / 10000 + 1;
        vm.deal(address(overseer), e.supply);
        token.syncSupply(e.supply, 0);
        token.syncSupply(e.supply, 0); // Refresh preSyncSupply; its known failure boundary has a separate regression.
        assertEq(token.preSyncSupply(), e.supply);
        assertEq(token.rewardsToSync(), 0);
        assertEq(token.totalShares(), e.shares);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(e.claim));
        assertEq(abi.encode(she.getWithdrawalRequest(otherId)), abi.encode(e.other));
        e.amount = e.claim.rawShares / G;
        assertEq(token.sharesToBalance(e.claim.rawShares), e.claim.rawShares * e.supply / e.shares);
        assertGt(e.amount, 1);
        if (mode == 0) e.liquid = 0;
        if (mode == 1) e.liquid = 1;
        if (mode == 2) e.liquid = e.amount * liquidBps / 10000;
        if (mode == 3) e.liquid = e.amount;
        if (mode == 4) e.liquid = e.amount + 1;
        if (mode == 5) e.liquid = e.amount - 1;
        setLiquidity(e.liquid);
        e.burnCountBefore = overseer.burnCount();
        assertEq(overseer.maxRedeemable(), e.liquid);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(alice.balance, 0);
        assertEq(bob.balance, 0);
        assertFalse(she.isLocked());
        e.held = token.sharesOf(address(she));
        e.config = abi.encode(she.configuration());
        e.rewards = rewardSnapshot();

        // Independent integer oracle: only whole wstHYPE quanta leave custody, regardless of the exchange rate.
        e.transferred = e.claim.rawShares / G * G;
        vm.expectCall(address(token), abi.encodeCall(stHYPE.transferShares, (address(she), alice, e.transferred)));
        assertLe(e.transferred, e.claim.rawShares);
        e.expected = storedAccounting();
        uint256 emission = (4 ether + 7) * G / 4;
        assertEq(e.expected.rewardRawShares, (4 ether + 7) * G);
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), 0);
        assertEq(e.expected.requestedRawShares, e.claim.rawShares + e.other.rawShares);
        assertEq(e.held, e.expected.activeRawShares + e.expected.requestedRawShares + e.expected.rewardRawShares + G);
        uint256 surplus = G + e.claim.rawShares - e.transferred;
        if (seedOnly) {
            assertEq(e.expected.totalOwnershipUnits, SEED);
            e.expected.rewardRawShares += surplus;
        } else {
            assertGt(e.expected.totalOwnershipUnits, SEED);
            e.expected.activeRawShares += emission + surplus;
            e.expected.rewardRawShares -= emission;
        }
        e.expected.requestedRawShares -= e.claim.rawShares;
        assertPreview(id, e.amount);
        vm.expectEmit(address(she));
        emitExpectedWithdrawalExecuted(id, e.amount);
        vm.prank(alice);
        uint256 paid = she.executeWithdrawal(id, e.amount);
        assertEq(paid, e.amount);
        assertEq(overseer.burnCount(), e.burnCountBefore);
        assertEq(token.sharesOf(address(she)), e.held - e.transferred);
        assertEq(token.totalShares(), e.shares);
        assertEq(token.totalSupply(), e.supply);
        assertEq(token.preSyncSupply(), e.supply);
        assertEq(wrapper.balanceOf(alice), e.amount);
        assertEq(token.sharesOf(alice), e.transferred);
        assertEq(bob.balance, 0);
        assertEq(alice.balance, 0);
        assertEq(address(overseer).balance, e.liquid);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(overseer.getNormalizedRedeemedHype(), 0);
        assertEq(abi.encode(storedAccounting()), abi.encode(e.expected));
        assertEq(abi.encode(she.totalAccounting()), abi.encode(e.expected));
        assertEq(uint256(vm.load(address(she), bytes32(SHE_SLOT + 9))), emission);
        {
            (I.RewardStream memory stream, uint256 retained) = she.rewardState();
            assertEq(abi.encode(stream), abi.encode(I.RewardStream((4 ether + 7) * G, emission, 1000, 1100)));
            assertEq(retained, seedOnly ? emission + surplus : 0);
        }
        assertEq(abi.encode(she.configuration()), e.config);
        if (!seedOnly) assertEq(rewardSnapshot(), e.rewards);
        e.claim.status = I.RequestStatus.EXECUTED;
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(e.claim));
        assertEq(abi.encode(she.getWithdrawalRequest(otherId)), abi.encode(e.other));
        (uint256 remainingAlice,,) = she.account(alice);
        (uint256 remainingBob,,) = she.account(bob);
        assertEq(remainingAlice, seedOnly ? 0 : aliceUnits - e.claim.rawShares);
        assertEq(remainingBob, seedOnly ? 0 : bobUnits - e.other.rawShares);
        assertFalse(she.isLocked());
        backed();
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
    }

    function assertPreview(uint256 id, uint256 expectedAmount) private view {
        bytes32 beforeState = snapshot();
        (bool eligible, uint256 amount) = lens.previewExecution(she, id);
        assertTrue(eligible);
        assertEq(amount, expectedAmount);
        assertEq(snapshot(), beforeState);
    }
}
