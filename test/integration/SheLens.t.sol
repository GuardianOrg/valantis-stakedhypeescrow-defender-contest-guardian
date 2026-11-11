// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {IStakedHypeEscrowToken} from "../../src/interfaces/IStakedHypeEscrowDependencies.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract SheLensTest is SheAssertions {
    error ModuleUnavailable();
    error EscrowUnavailable();

    function test_allPreviewsUseTheSuppliedEscrowAndPreserveBothInstances() public {
        deposit(alice, 10 ether);
        request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether);
        StakedHypeEscrow firstEscrow = she;
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(I.initialize, (params()))
                )
            )
        );
        deposit(alice, 20 ether);
        request(alice, 3 ether * 1e6);
        vm.prank(manager);
        she.setPaused(true);
        bytes32 secondBefore = snapshot();
        StakedHypeEscrow secondEscrow = she;
        she = firstEscrow;
        bytes32 firstBefore = snapshot();
        she = secondEscrow;
        for (uint256 i; i < 2; ++i) {
            // Interleave calls so accidental cross-instance configuration/accounting reuse is detectable.
            (uint256 units, uint256 charge, uint256 unspent) = lens.previewDeposit(firstEscrow, 5 ether);
            assertEq(units, 4 ether * 1e6); // First pool: A/U = 10/8.
            assertEq(charge, 5 ether);
            assertEq(unspent, 0);
            (units, charge, unspent) = lens.previewDeposit(she, 5 ether);
            assertEq(units, 5 ether * 1e6); // Second pool: A/U = 17/17.
            assertEq(charge, 5 ether);
            assertEq(unspent, 0);
            assertEq(lens.previewRequestWithdrawal(firstEscrow, alice, 4 ether * 1e6), 5 ether * 1e6);
            assertEq(lens.previewRequestWithdrawal(she, alice, 4 ether * 1e6), 4 ether * 1e6);
            assertEq(lens.previewCancelWithdrawal(firstEscrow, 1), 1.6 ether * 1e6);
            assertEq(lens.previewCancelWithdrawal(she, 1), 3 ether * 1e6);
            (bool eligible, uint256 amount) = lens.previewExecution(firstEscrow, 1);
            assertTrue(eligible);
            assertEq(amount, 2 ether);
            assertPreview(1, false, 3 ether);
        }
        assertEq(snapshot(), secondBefore);
        she = firstEscrow;
        assertEq(snapshot(), firstBefore);
        assertEq(she.getWithdrawalRequest(1).owner, alice);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(8 ether * 1e6, 8 ether * 1e6, 2 ether * 1e6, 4 ether * 1e6))
        );
        assertEq(token.sharesOf(address(she)), 15 ether * 1e6);
        assertFalse(she.paused());
        backed();
    }

    function test_requestPreviewEnforcesOwnerUnitsWithIndependentRewardAndDonationQuote() public {
        uint256 aliceUnits = deposit(alice, 10 ether);
        deposit(bob, 30 ether);
        request(bob, 10 ether * 1e6);
        fund(6 ether);
        vm.warp(block.timestamp + 50);
        donate(3 ether);
        bytes32 beforeState = snapshot();
        // A = 30 principal + 3 elapsed reward + 3 donation; U = 30, including the seed.
        uint256 expected = aliceUnits * (36 ether * 1e6) / (30 ether * 1e6);
        assertEq(lens.previewRequestWithdrawal(she, alice, aliceUnits), expected);
        assertEq(lens.previewRequestWithdrawal(she, alice, 0), 0);
        vm.expectRevert(I.StakedHypeEscrow__InsufficientUnits.selector);
        lens.previewRequestWithdrawal(she, alice, aliceUnits + 1);
        vm.expectRevert(I.StakedHypeEscrow__InsufficientUnits.selector);
        lens.previewRequestWithdrawal(she, address(0xCA401), 1);
        assertEq(snapshot(), beforeState);
        uint256 id = request(alice, aliceUnits);
        assertEq(she.getWithdrawalRequest(id).rawShares, expected);
        assertEq(storedAccounting().requestedRawShares, 10 ether * 1e6 + expected);
        assertEq(storedAccounting().activeRawShares, 36 ether * 1e6 - expected);
        assertEq(storedAccounting().rewardRawShares, 3 ether * 1e6);
        backed();
    }

    function test_requestPreviewUsesFullPrecisionAtLargeBalances() public {
        assertLargeRequestQuote(type(uint256).max / 2, false);
    }

    function testFuzz_requestPreviewRoundsDownWithOverflowingIntermediate(uint256 unitsSeed) public {
        assertLargeRequestQuote(unitsSeed, true);
    }

    function test_requestPreviewAllowsAllOwnerUnitsWithOverflowingIntermediate() public {
        assertLargeRequestQuote(2e40 - SEED, true);
    }

    function assertLargeRequestQuote(uint256 unitsSeed, bool withDonation) private {
        // A backed loss followed by real mints creates large shares without synthetic SHE storage.
        token.syncSupply(1, 0);
        vm.deal(address(overseer), 1);
        uint256 ownerUnits = depositAfterLoss(alice);
        uint256 bobUnits = depositAfterLoss(bob);
        request(bob, 1 ether * 1e6);
        bytes memory otherRequest = abi.encode(she.getWithdrawalRequest(1));
        I.Accounting memory expected = storedAccounting();
        assertEq(expected.activeRawShares, expected.totalOwnershipUnits);
        uint256 units = bound(unitsSeed, 2 ** 129, ownerUnits);
        uint256 raw = units;
        if (withDonation) {
            overseer.mint{value: 3 ether}(address(this));
            assertEq(expected.totalOwnershipUnits % 1e6, 0);
            assertTrue(wrapper.transfer(address(she), expected.totalOwnershipUnits / 1e6 + 1));
            expected.activeRawShares = 2 * expected.totalOwnershipUnits + 1e6;
            // A = 2U + 1e6. This independent quotient never multiplies the two large operands.
            raw = 2 * units + units * 1e6 / expected.totalOwnershipUnits;
            if (units * 1e6 % expected.totalOwnershipUnits == 0) {
                --units;
                raw = 2 * units + units * 1e6 / expected.totalOwnershipUnits;
            }
            assertGt(units * 1e6 % expected.totalOwnershipUnits, 0, "must exercise floor rounding");
        }
        assertGt(units, type(uint256).max / expected.activeRawShares, "product must overflow uint256");
        bytes32 beforeState = snapshot();
        assertEq(lens.previewRequestWithdrawal(she, alice, units), raw);
        assertEq(lens.previewRequestWithdrawal(she, alice, 0), 0);
        vm.expectRevert(I.StakedHypeEscrow__InsufficientUnits.selector);
        lens.previewRequestWithdrawal(she, alice, ownerUnits + 1);
        vm.expectRevert(I.StakedHypeEscrow__InvalidAddress.selector);
        lens.previewRequestWithdrawal(she, address(1), SEED);
        assertEq(snapshot(), beforeState, "quotes must preserve uncheckpointed surplus and all state");
        reject(
            alice,
            0,
            abi.encodeCall(I.requestWithdrawal, (units, raw + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        bytes32 assetsBefore = requestAssetsSnapshot();
        expected.activeRawShares -= raw;
        expected.totalOwnershipUnits -= units;
        expected.requestedRawShares += raw;
        vm.expectEmit(address(she));
        emit I.WithdrawalRequested(2, alice, units, raw, 1010, expectedAccount(ownerUnits - units, expected), expected);
        vm.prank(alice);
        uint256 id = she.requestWithdrawal(units, raw);
        assertEq(id, 2);
        assertEq(
            abi.encode(she.getWithdrawalRequest(id)),
            abi.encode(I.WithdrawalRequest(alice, raw, 1000, 1010, I.RequestStatus.REQUESTED))
        );
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        (uint256 remaining,,) = she.account(alice);
        assertEq(remaining, ownerUnits - units);
        (remaining,,) = she.account(bob);
        assertEq(remaining, bobUnits - 1 ether * 1e6);
        (remaining,,) = she.account(address(1));
        assertEq(remaining, SEED);
        assertEq(requestAssetsSnapshot(), assetsBefore, "request must not transfer or burn assets");
        assertEq(abi.encode(she.getWithdrawalRequest(1)), otherRequest);
        assertFalse(she.isLocked());
        backed();
        executeAndAssertPayout(alice, id, raw / 1e6);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), otherRequest);
    }

    function depositAfterLoss(address owner) private returns (uint256 units) {
        // The upstream seed has 0.02e24 shares against one nominal wei after the loss.
        uint256 raw = 0.02 ether * 1e6 * 1 ether;
        overseer.mint{value: 1 ether}(owner);
        assertEq(token.sharesOf(owner), raw);
        bool first = storedAccounting().totalOwnershipUnits == 0;
        uint256 held = token.sharesOf(address(she));
        vm.startPrank(owner);
        wrapper.approve(address(she), raw / 1e6);
        uint256 accepted;
        (units, accepted) = she.deposit(raw / 1e6, owner, raw - (first ? SEED : 0), raw / 1e6);
        vm.stopPrank();
        assertEq(units, raw - (first ? SEED : 0));
        assertEq(accepted, raw / 1e6);
        assertEq(token.sharesOf(owner), 0);
        assertEq(wrapper.balanceOf(owner), 0);
        assertEq(wrapper.allowance(owner, address(she)), 0);
        assertEq(token.sharesOf(address(she)), held + raw);
        backed();
    }

    function requestAssetsSnapshot() private view returns (bytes32 digest) {
        address[6] memory actors = [address(this), alice, bob, address(she), address(overseer), address(1)];
        for (uint256 i; i < actors.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    actors[i].balance,
                    token.sharesOf(actors[i]),
                    wrapper.balanceOf(actors[i]),
                    wrapper.allowance(actors[i], address(she)),
                    wrapper.allowance(address(she), actors[i])
                )
            );
        }
        return keccak256(
            abi.encode(
                digest,
                token.totalShares(),
                token.totalSupplyRaw(),
                overseer.getAllBurns(),
                overseer.totalPendingBurns(),
                overseer.redeemed(),
                she.configuration(),
                rewardSnapshot(),
                she.paused()
            )
        );
    }

    function matureRequest() private returns (uint256 id) {
        uint256 aliceUnits = deposit(alice, 10 ether);
        uint256 bobUnits = deposit(bob, 4 ether);
        assertEq(aliceUnits, 10 ether * 1e6 - SEED);
        id = request(alice, 6 ether * 1e6);
        request(bob, bobUnits / 4);
        // Leave surplus uncheckpointed so a failed funding attempt must also undo its checkpoint.
        donate(1 ether);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        setLiquidity(2 ether);
    }

    function assertPreview(uint256 id, bool expectedEligible, uint256 expectedAmount) private view {
        (bool eligible, uint256 amount) = lens.previewExecution(she, id);
        assertEq(eligible, expectedEligible);
        assertEq(amount, expectedAmount);
    }

    function test_previewKeepsRequiredEscrowReadsStrict() public {
        uint256 id = matureRequest();
        bytes32 beforeState = snapshot();
        bytes memory reason = abi.encodeWithSelector(EscrowUnavailable.selector);
        bytes[3] memory reads = [
            abi.encodeCall(I.getWithdrawalRequest, (id)),
            abi.encodeCall(I.paused, ()),
            abi.encodeCall(I.RAW_SHARES_PER_WSTHYPE_WEI, ())
        ];
        for (uint256 i; i < reads.length; ++i) {
            vm.mockCallRevert(address(she), reads[i], reason);
            vm.expectRevert(reason);
            lens.previewExecution(she, id);
            vm.clearMockedCalls();
            assertEq(snapshot(), beforeState);
        }
        bytes[2] memory cancellationReads =
            [abi.encodeCall(I.getWithdrawalRequest, (id)), abi.encodeCall(I.totalAccounting, ())];
        for (uint256 i; i < cancellationReads.length; ++i) {
            vm.mockCallRevert(address(she), cancellationReads[i], reason);
            vm.expectRevert(reason);
            lens.previewCancelWithdrawal(she, id);
            vm.clearMockedCalls();
            assertEq(snapshot(), beforeState);
        }
    }

    function test_previewAndExecutionMakeNoDirectLiquidityOrNominalConversionCalls() public {
        uint256 id = matureRequest();
        bytes memory other = abi.encode(she.getWithdrawalRequest(2));
        bytes memory reason = abi.encodeWithSelector(ModuleUnavailable.selector);
        vm.mockCallRevert(address(liquidityModule), abi.encodeWithSignature("getTotalBalance()"), reason);
        vm.mockCallRevert(address(overseer), abi.encodeWithSignature("maxRedeemable()"), reason);
        // This external-selector mock does not intercept transferShares' internal event conversion.
        // SheDependencyConversionTest covers that fixed dependency's arithmetic boundary separately.
        vm.mockCallRevert(
            address(token), abi.encodeCall(IStakedHypeEscrowToken.sharesToBalance, (6 ether * 1e6)), reason
        );
        assertPreview(id, true, 6 ether);
        uint256 count = overseer.burnCount();
        uint256 shares = token.totalShares();
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        assertEq(she.executeWithdrawal(id, 6 ether), 6 ether);
        assertEq(wrapper.balanceOf(alice), 6 ether);
        assertEq(overseer.burnCount(), count);
        assertEq(token.totalSupply(), supply);
        assertEq(token.totalShares(), shares);
        assertEq(alice.balance, 0);
        assertEq(abi.encode(she.getWithdrawalRequest(2)), other);
        vm.clearMockedCalls();
        assertPreview(id, false, 0);
        assertEq(she.totalAccounting().requestedRawShares, 1 ether * 1e6);
        backed();
    }

    function test_failedFundingWithUnavailableModuleDoesNotBlockExit() public {
        uint256 id = matureRequest();
        bytes32 beforeState = snapshot();
        bytes memory reason = abi.encodeWithSelector(ModuleUnavailable.selector);
        vm.mockCallRevert(address(liquidityModule), abi.encodeWithSignature("getTotalBalance()"), reason);
        vm.expectRevert(reason);
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(1);
        vm.clearMockedCalls();
        assertEq(snapshot(), beforeState);
        executeAndAssertPayout(alice, id, 6 ether);
    }

    function test_zeroLiquidityAndExistingQueueStayUnchangedByExit() public {
        uint256 id = matureRequest();
        overseer.mint{value: 3 ether}(bob);
        vm.prank(bob);
        uint256 earlier = overseer.burn(bob, 3 ether);
        setLiquidity(0);
        assertPreview(id, true, 6 ether);
        executeAndAssertPayout(alice, id, 6 ether);
        assertBurn(earlier, 3 ether, bob, false);
        assertEq(overseer.totalPendingBurns(), 3 ether);
        assertEq(bob.balance, 0);
        setLiquidity(3 ether);
        overseer.redeem(earlier);
        assertEq(bob.balance, 3 ether);
        assertEq(wrapper.balanceOf(alice), 6 ether);
    }

    function test_nonRequestedIdsSkipAllOtherReads() public {
        uint256 id = matureRequest();
        executeAndAssertPayout(alice, id, 6 ether);
        bytes32 beforeState = snapshot();
        bytes memory reason = abi.encodeWithSelector(EscrowUnavailable.selector);
        vm.mockCallRevert(address(she), abi.encodeCall(I.paused, ()), reason);
        vm.mockCallRevert(address(she), abi.encodeCall(I.RAW_SHARES_PER_WSTHYPE_WEI, ()), reason);
        vm.mockCallRevert(address(she), abi.encodeCall(I.totalAccounting, ()), reason);
        assertPreview(id, false, 0);
        assertPreview(id + 100, false, 0);
        assertEq(lens.previewCancelWithdrawal(she, id), 0);
        assertEq(lens.previewCancelWithdrawal(she, id + 100), 0);
        vm.clearMockedCalls();
        assertEq(snapshot(), beforeState);
    }
}
