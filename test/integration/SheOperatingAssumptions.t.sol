// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stdError} from "forge-std/StdError.sol";

// Local development evidence for the external supply assumption and accepted DEV-01 behavior.
// Backing loss is injected with vm.deal; this does not model HyperCore or production operating controls.
contract SheOperatingAssumptionsTest is SheAssertions {
    uint256 private constant SUPPLY_CEILING = 1_000_000_000 ether;
    uint256 private constant CIRCULATING = 0.04 ether;
    uint256 private constant PENDING = 10_000_000 ether;
    uint256 private constant REQUEST_SHARES = 0.01 ether * 1e6;
    uint256 private burnId;

    function test_nominalSupplyCeilingIsAnExternalAssumption() public {
        uint256 units = deposit(alice, 1 ether);
        vm.deal(address(this), SUPPLY_CEILING);
        overseer.mint{value: SUPPLY_CEILING - token.totalSupply()}(bob);
        assertEq(token.totalSupply(), SUPPLY_CEILING);
        assertEq(overseer.getTotalBalance(), SUPPLY_CEILING);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(overseer.protocolPendingFee(), 0);
        I.Accounting memory beforeAccounting = she.totalAccounting();
        assertEq(beforeAccounting.activeRawShares, 1 ether * 1e6);
        assertEq(beforeAccounting.totalOwnershipUnits, 1 ether * 1e6);

        assertEq(deposit(alice, 1), 1e6);
        assertEq(token.totalSupply(), SUPPLY_CEILING + 1);
        assertEq(overseer.getTotalBalance(), SUPPLY_CEILING + 1);
        assertEq(token.totalShares(), (SUPPLY_CEILING + 1) * 1e6);
        beforeAccounting.activeRawShares += 1e6;
        beforeAccounting.totalOwnershipUnits += 1e6;
        assertEq(abi.encode(she.totalAccounting()), abi.encode(beforeAccounting));
        (uint256 afterUnits,,) = she.account(alice);
        assertEq(afterUnits, units + 1e6);
        assertEq(wrapper.allowance(alice, address(she)), 0);
        uint256 id = request(alice, 1e6);
        assertEq(she.getWithdrawalRequest(id).rawShares, 1e6);
        executeAndAssertPayout(alice, id, 1);
    }

    function test_ignoredLossConcentratesOnCirculatingHolders() public {
        prepareIgnoredLoss(0.03 ether);
        bytes32 escrowBefore = escrowSnapshot();
        bytes32 burnsBefore = keccak256(abi.encode(overseer.getAllBurns()));
        assertEq(token.sharesToBalance(REQUEST_SHARES), 0.01 ether);
        overseer.rebase();
        assertEq(token.totalSupply(), 0.01 ether); // 75% holder loss despite being below the total-claims threshold.
        assertEq(token.sharesToBalance(REQUEST_SHARES), 0.0025 ether);
        assertEq(overseer.totalPendingBurns(), PENDING);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
        assertEq(keccak256(abi.encode(overseer.getAllBurns())), burnsBefore);
        assertEq(overseer.getTotalBalance(), PENDING + 0.01 ether);
        assertEq(overseer.protocolPendingFee(), 0);
        assertEq(overseer.lastRebaseTime(), block.timestamp);
        assertEq(escrowSnapshot(), escrowBefore);
        executeAndAssertPayout(alice, 1, 0.01 ether);
    }

    function test_ignoredLossCanZeroSupplyAndTopUpDoesNotRestartRebase() public {
        prepareIgnoredLoss(CIRCULATING);
        bytes32 escrowBefore = escrowSnapshot();
        bytes32 burnsBefore = keccak256(abi.encode(overseer.getAllBurns()));
        overseer.rebase();
        assertEq(token.totalSupply(), 0);
        assertEq(token.preSyncSupply(), 0);
        assertEq(token.totalShares(), CIRCULATING * 1e6);
        assertEq(overseer.totalPendingBurns(), PENDING);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18); // Distinct from the zero-factor total-loss case.
        assertEq(keccak256(abi.encode(overseer.getAllBurns())), burnsBefore);
        assertEq(escrowSnapshot(), escrowBefore);
        executeAndAssertPayout(alice, 1, 0.01 ether);
        assertEq(token.balanceOf(alice), 0);
        overseer.receiveHYPE{value: CIRCULATING}();
        assertEq(overseer.getTotalBalance(), PENDING + CIRCULATING);
        assertEq(token.totalSupply(), 0);
        vm.warp(block.timestamp + 1);
        assertRebaseRejected(stdError.divisionError);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
    }

    function test_ignoredLossAboveCirculatingSupplyRevertsWithFullRollback() public {
        prepareIgnoredLoss(0.05 ether);
        assertLt(overseer.getTotalBalance(), overseer.totalPendingBurns());
        assertRebaseRejected(stdError.arithmeticError);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
        assertEq(token.totalSupply(), CIRCULATING);
        executeAndAssertPayout(alice, 1, 0.01 ether);
    }

    function test_unmintedTopUpBeforeRebaseRestoresBacking() public {
        uint256 loss = 0.05 ether;
        prepareIgnoredLoss(loss);
        bytes32 escrowBefore = escrowSnapshot();
        bytes32 burnsBefore = keccak256(abi.encode(overseer.getAllBurns()));
        uint256 supplyBefore = token.totalSupply();
        uint256 payerBefore = address(this).balance;
        overseer.receiveHYPE{value: loss}();
        assertEq(address(this).balance, payerBefore - loss);
        assertEq(overseer.getTotalBalance(), PENDING + CIRCULATING);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(escrowSnapshot(), escrowBefore);
        overseer.rebase();
        assertEq(token.totalSupply(), CIRCULATING);
        assertEq(overseer.totalPendingBurns(), PENDING);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
        assertEq(overseer.protocolPendingFee(), 0);
        assertEq(keccak256(abi.encode(overseer.getAllBurns())), burnsBefore);
        assertEq(escrowSnapshot(), escrowBefore);
        executeAndAssertPayout(alice, 1, 0.01 ether);
    }

    function test_recognizingSmallLossBeforeRebaseSharesItWithQueuedClaims() public {
        prepareIgnoredLoss(0.05 ether);
        uint256 backing = overseer.getTotalBalance();
        uint256 factor = backing * 1e18 / (PENDING + CIRCULATING);
        uint256 expectedPending = (PENDING * factor + 1e18 - 1) / 1e18; // Independent ceil oracle.
        uint256 expectedSupply = backing - expectedPending;
        assertGt(expectedSupply, 0);
        assertLt(expectedSupply, CIRCULATING);
        assertLt(expectedPending, PENDING);
        bytes32 escrowBefore = escrowSnapshot();
        bytes32 burnsBefore = keccak256(abi.encode(overseer.getAllBurns()));
        // Fixture-only choices, not recommended production threshold values.
        overseer.setMinSlashPercentage(0);
        overseer.setMaxSlashPercentage(1e18 - factor);
        assertTrue(overseer.pendingSlashExists());
        overseer.rebase();
        assertEq(overseer.getLatestCumulativeSlashFactor(), factor);
        assertEq(overseer.totalPendingBurns(), expectedPending);
        assertEq(token.totalSupply(), expectedSupply);
        assertEq(token.totalSupply() + overseer.totalPendingBurns(), backing);
        assertEq(overseer.protocolPendingFee(), 0);
        assertEq(overseer.getCumulativeSlashFactor(burnId), 1e18);
        assertEq(overseer.getCumulativeNormalizedBurns(burnId), PENDING);
        assertEq(keccak256(abi.encode(overseer.getAllBurns())), burnsBefore);
        assertEq(escrowSnapshot(), escrowBefore);
        executeAndAssertPayout(alice, 1, 0.01 ether);
    }

    function test_rewardMintingDoesNotExtinguishIgnoredShortfall() public {
        uint256 loss = 0.05 ether;
        prepareIgnoredLoss(loss);
        I.Accounting memory expected = she.totalAccounting();
        bytes memory withdrawalBefore = abi.encode(she.getWithdrawalRequest(1));
        uint256 distributorBefore = distributor.balance;
        uint256 heldBefore = token.sharesOf(address(she));
        uint256 sharesBefore = token.totalShares();
        uint256 backingBefore = overseer.getTotalBalance();
        bytes32 burnsBefore = keccak256(abi.encode(overseer.getAllBurns()));
        fund(1 ether);
        expected.rewardRawShares += 1 ether * 1e6;
        assertEq(abi.encode(she.totalAccounting()), abi.encode(expected));
        assertEq(abi.encode(she.getWithdrawalRequest(1)), withdrawalBefore);
        assertEq(token.sharesOf(address(she)), heldBefore + 1 ether * 1e6);
        assertEq(token.totalShares(), sharesBefore + 1 ether * 1e6);
        assertEq(token.totalSupply(), CIRCULATING + 1 ether);
        assertEq(distributor.balance, distributorBefore - 1 ether);
        assertEq(overseer.getTotalBalance(), backingBefore + 1 ether);
        assertEq(token.totalSupply() + overseer.totalPendingBurns() - overseer.getTotalBalance(), loss);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
        assertEq(overseer.protocolPendingFee(), 0);
        assertEq(keccak256(abi.encode(overseer.getAllBurns())), burnsBefore);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(stream.totalRawShares, 1 ether * 1e6);
        assertEq(stream.releasedRawShares, 0);
        assertEq(stream.start, block.timestamp);
        assertEq(stream.end, block.timestamp + 100);
        assertEq(retained, 0);
        backed();
    }

    function prepareIgnoredLoss(uint256 loss) private {
        deposit(alice, 0.02 ether);
        assertEq(request(alice, REQUEST_SHARES), 1);
        assertEq(she.getWithdrawalRequest(1).rawShares, REQUEST_SHARES);
        vm.deal(address(this), PENDING + 1 ether);
        overseer.mint{value: PENDING}(bob);
        burnId = overseer.burnCount();
        assertEq(burnId, 2); // initialize and initializeV3 each append a completed zero-amount sentinel.
        assertBurn(0, 0, address(0), true);
        assertBurn(1, 0, address(0), true);
        vm.prank(bob);
        overseer.burn(bob, PENDING);
        assertEq(token.totalSupply(), CIRCULATING);
        assertEq(token.totalShares(), CIRCULATING * 1e6);
        assertEq(overseer.totalPendingBurns(), PENDING);
        assertEq(overseer.getTotalBalance(), PENDING + CIRCULATING);
        assertEq(overseer.protocolPendingFee(), 0);
        assertEq(overseer.burnCount(), burnId + 1);
        assertBurn(burnId, PENDING, bob, false);
        assertEq(overseer.getLatestCumulativeSlashFactor(), 1e18);
        assertEq(overseer.getMinSlashPercentage(), 1e10);
        assertEq(overseer.maxSlashPercentage(), 0);
        vm.warp(block.timestamp + 1);
        assertGt(block.timestamp, token.syncEnd());
        // Synthetic backing loss; the pending claim and token supply remain unchanged until rebase.
        vm.deal(address(overseer), PENDING + CIRCULATING - loss);
        uint256 slashPercentage = 1e18 - (PENDING + CIRCULATING - loss) * 1e18 / (PENDING + CIRCULATING);
        assertGt(slashPercentage, 0);
        assertLt(slashPercentage, overseer.getMinSlashPercentage());
        assertFalse(overseer.pendingSlashExists());
        backed();
    }

    function assertRebaseRejected(bytes memory reason) private {
        bytes32 beforeState = snapshot();
        uint256 lastRebase = overseer.lastRebaseTime();
        vm.expectRevert(reason);
        overseer.rebase();
        assertEq(snapshot(), beforeState);
        assertEq(overseer.lastRebaseTime(), lastRebase);
    }

    function escrowSnapshot() private view returns (bytes32 digest) {
        // Deliberately excludes nominal balances/supply: rebase changes those, not raw custody or SHE state.
        for (uint256 i; i < 15; ++i) {
            digest = keccak256(abi.encode(digest, vm.load(address(she), bytes32(SHE_SLOT + i))));
        }
        (uint256 units, uint256 active, uint256 wrapped) = she.account(alice);
        digest = keccak256(abi.encode(digest, units, active, wrapped, she.getWithdrawalRequest(1), rewardSnapshot()));
        digest = keccak256(
            abi.encode(
                digest,
                she.totalAccounting(),
                token.totalShares(),
                token.sharesOf(address(she)),
                token.sharesOf(alice),
                token.sharesOf(bob),
                wrapper.allowance(alice, address(she))
            )
        );
    }
}
