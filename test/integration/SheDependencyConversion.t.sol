// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Negative regression for the fixed token's internal transfer-event conversion.
// Extreme losses/backing are simulated locally; actual protocol calls create shares and requests.
// Passing confirms the dependency boundary and atomic rollback, not general withdrawal liveness.
contract SheDependencyConversionTest is SheAssertions {
    uint256 constant G = 1e6;
    address stranger = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        extraActors.push(stranger);
    }

    function depositAtCurrentRate(address owner) private returns (uint256 units) {
        overseer.mint{value: 1 ether}(owner);
        uint256 rawBefore = token.sharesOf(owner);
        uint256 amount = rawBefore / G;
        uint256 held = token.sharesOf(address(she));
        I.Accounting memory expected = storedAccounting();
        assertEq(expected.activeRawShares, expected.totalOwnershipUnits);
        uint256 seed = expected.totalOwnershipUnits == 0 ? SEED : 0;
        vm.startPrank(owner);
        wrapper.approve(address(she), amount);
        uint256 accepted;
        (units, accepted) = she.deposit(amount, owner, amount * G - seed, amount);
        vm.stopPrank();
        assertEq(units, amount * G - seed);
        assertEq(accepted, amount);
        assertEq(token.sharesOf(owner), rawBefore % G);
        assertEq(wrapper.allowance(owner, address(she)), 0);
        assertEq(token.sharesOf(address(she)), held + amount * G);
        expected.activeRawShares += amount * G;
        expected.totalOwnershipUnits += amount * G;
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        backed();
    }

    function prepareLargeShareRequest() private returns (uint256 id, uint256 amount) {
        overseer.setMaxSlashPercentage(0.6e18);
        for (uint256 i; i < 80; ++i) {
            vm.warp(token.syncEnd() + 1);
            vm.deal(address(overseer), address(overseer).balance / 2);
            overseer.rebase();
            overseer.mint{value: 1 ether}(address(this));
        }
        uint256 units = depositAtCurrentRate(alice);
        depositAtCurrentRate(bob);
        id = request(alice, units / 2);
        request(bob, units / 4);
        uint256 raw = she.getWithdrawalRequest(id).rawShares;
        assertEq(raw, units / 2); // No SHE rewards or donations: A == U.
        assertGt(token.sharesToBalance(raw), 0);
        assertLt(token.totalSupply(), 5 ether);
        bytes memory beforeRecovery = abi.encode(
            storedAccounting(),
            rewardSnapshot(),
            she.getWithdrawalRequest(id),
            she.getWithdrawalRequest(2),
            token.sharesOf(address(she))
        );

        // Authorized fixture recovery below the documented 1B nominal supply ceiling.
        // It is not a production occurrence or a claim that arbitrary losses can be repaired.
        overseer.changeProtocolFee(0);
        overseer.setAprThreshold(1e30);
        vm.deal(address(overseer), 100_000_000 ether);
        vm.warp(token.syncEnd() + 1);
        overseer.rebase();
        vm.warp(token.syncEnd() + 1);
        vm.warp(Math.max(block.timestamp, she.getWithdrawalRequest(id).eligibleAt));
        assertEq(token.totalSupply(), 100_000_000 ether);
        assertEq(overseer.getTotalBalance(), token.totalSupply());
        assertEq(overseer.totalPendingBurns(), 0);
        assertLt(token.totalShares(), type(uint208).max);
        assertEq(
            abi.encode(
                storedAccounting(),
                rewardSnapshot(),
                she.getWithdrawalRequest(id),
                she.getWithdrawalRequest(2),
                token.sharesOf(address(she))
            ),
            beforeRecovery
        );
        amount = raw / G;
        assertGt(amount * G, type(uint256).max / token.totalSupplyRaw());
        uint256 preciseNominal = Math.mulDiv(amount * G, token.totalSupplyRaw(), token.totalShares() * G);
        assertGt(preciseNominal, 0);
        assertLt(preciseNominal, token.totalSupply());
        (bool eligible, uint256 quote) = lens.previewExecution(she, id);
        assertTrue(eligible);
        assertEq(quote, amount);
        backed();
    }

    function rejectOverflowForOwnerAndStranger(uint256 id, uint256 amount) private {
        // Solmate mulDivDown returns exactly empty revert data on intermediate overflow.
        // The shared rejection helper compares every request, custody, wallets, allowances,
        // stored buckets/stream, governance and upstream accounting before and after each call.
        reject(alice, 0, abi.encodeCall(I.executeWithdrawal, (id, amount)), bytes(""));
        reject(stranger, 0, abi.encodeCall(I.executeWithdrawal, (id, 0)), bytes(""));
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.REQUESTED));
        assertFalse(she.isLocked());
        backed();
    }

    function test_dependencyEventConversionOverflowPreservesRequestAndAllState() public {
        (uint256 id, uint256 amount) = prepareLargeShareRequest();
        rejectOverflowForOwnerAndStranger(id, amount);
        // SHE's limited preview is still ready; neither rejected execution resolved the request.
        (bool eligible, uint256 quote) = lens.previewExecution(she, id);
        assertTrue(eligible);
        assertEq(quote, amount);
    }

    function cancelAndAssert(uint256 id) private returns (uint256 units) {
        I.WithdrawalRequest memory original = she.getWithdrawalRequest(id);
        I.Accounting memory expected = storedAccounting();
        assertEq(expected.activeRawShares, expected.totalOwnershipUnits);
        units = original.rawShares; // Independently known q * U / A == q in this history.
        assertEq(lens.previewCancelWithdrawal(she, id), units);
        bytes32 assets = assetState();
        bytes32 rewards = rewardSnapshot();
        bytes memory config = abi.encode(she.configuration());
        (uint256 ownerBefore,,) = she.account(alice);
        (uint256 bobBefore,,) = she.account(bob);
        reject(
            stranger,
            0,
            abi.encodeCall(I.cancelWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__OnlyRequestOwner.selector)
        );
        reject(
            alice,
            0,
            abi.encodeCall(I.cancelWithdrawal, (id, units + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        vm.expectEmit(address(she));
        emitExpectedWithdrawalCancelled(id, alice, original.rawShares, units);
        vm.prank(alice);
        assertEq(she.cancelWithdrawal(id, units), units);
        expected.activeRawShares += units;
        expected.totalOwnershipUnits += units;
        expected.requestedRawShares -= original.rawShares;
        original.status = I.RequestStatus.CANCELLED;
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(original));
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        assertEq(abi.encode(she.totalAccounting()), abi.encode(expected));
        (uint256 ownerAfter,,) = she.account(alice);
        (uint256 bobAfter,,) = she.account(bob);
        (uint256 seedUnits,,) = she.account(address(1));
        assertEq(ownerAfter, ownerBefore + units);
        assertEq(bobAfter, bobBefore);
        assertEq(seedUnits, SEED);
        assertEq(assetState(), assets, "cancellation changed assets or upstream state");
        assertEq(rewardSnapshot(), rewards);
        assertEq(abi.encode(she.configuration()), config);
        assertFalse(she.isLocked());
        backed();
    }

    function assetState() private view returns (bytes32 digest) {
        address[10] memory actors = [
            address(this),
            alice,
            bob,
            stranger,
            manager,
            distributor,
            upgradeGov,
            address(she),
            address(overseer),
            address(1)
        ];
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
        return keccak256(
            abi.encode(
                digest,
                token.totalShares(),
                token.totalSupply(),
                token.preSyncSupply(),
                token.rewardsToSync(),
                token.syncStart(),
                token.syncEnd(),
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

    function assertOwnerAndStrangerSettlement(uint256 id, uint256 amount) private {
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        uint256 ownerRaw = token.sharesOf(alice);
        uint256 ownerBalance = wrapper.balanceOf(alice);
        uint256 callerRaw = token.sharesOf(stranger);
        uint256 saved = vm.snapshot();
        executeAndAssertPayout(alice, id, amount); // Independent exact accounting/custody oracle.
        bytes32 expected = snapshot();
        assertTrue(vm.revertToAndDelete(saved));
        vm.expectEmit(address(she));
        emitExpectedWithdrawalExecuted(id, amount);
        vm.prank(stranger);
        assertEq(she.executeWithdrawal(id, 0), amount);
        assertEq(token.sharesOf(alice), ownerRaw + amount * G);
        assertEq(wrapper.balanceOf(alice), ownerBalance + amount);
        assertEq(token.sharesOf(stranger), callerRaw);
        assertEq(snapshot(), expected, "third-party settlement differs from verified owner settlement");
        backed();
    }

    function test_cancellationAndSmallerRequestRemainAvailableAfterConversionOverflow() public {
        (uint256 id, uint256 amount) = prepareLargeShareRequest();
        rejectOverflowForOwnerAndStranger(id, amount);
        I.WithdrawalRequest memory other = she.getWithdrawalRequest(2);
        uint256 originalMaturity = she.getWithdrawalRequest(id).eligibleAt;
        uint256 units = cancelAndAssert(id);
        assertEq(abi.encode(she.getWithdrawalRequest(2)), abi.encode(other));
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );

        uint256 safeRaw = type(uint256).max / token.totalSupplyRaw() / G * G;
        assertGt(safeRaw, 0);
        assertLt(safeRaw, units);
        assertLe(safeRaw, type(uint256).max / token.totalSupplyRaw());
        assertGt(safeRaw + G, type(uint256).max / token.totalSupplyRaw());
        I.Accounting memory expected = storedAccounting();
        uint256 smaller = request(alice, safeRaw);
        assertEq(smaller, 3);
        expected.activeRawShares -= safeRaw;
        expected.totalOwnershipUnits -= safeRaw;
        expected.requestedRawShares += safeRaw;
        assertEq(abi.encode(storedAccounting()), abi.encode(expected));
        assertEq(
            abi.encode(she.getWithdrawalRequest(smaller)),
            abi.encode(
                I.WithdrawalRequest(
                    alice, safeRaw, uint64(block.timestamp), uint64(block.timestamp + 10), I.RequestStatus.REQUESTED
                )
            )
        );
        assertGt(she.getWithdrawalRequest(smaller).eligibleAt, originalMaturity);
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (smaller, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        assertOwnerAndStrangerSettlement(smaller, safeRaw / G);
        assertEq(abi.encode(she.getWithdrawalRequest(2)), abi.encode(other));
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (smaller, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
    }
}
