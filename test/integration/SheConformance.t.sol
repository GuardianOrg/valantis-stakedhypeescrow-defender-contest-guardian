// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {Test, stdError} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {StakedHypeEscrowLens} from "../../src/StakedHypeEscrowLens.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";
import {Overseer} from "../../src/Overseer.sol";

import {SheTestBase, RejectingRecipient, LockObservingRecipient} from "../helpers/SheTestBase.sol";

contract SheConformanceTest is SheTestBase {
    function test_atomicInitAndSeparateUpgradeAuthority() public {
        assertEq(she.defaultAdmin(), address(this));
        assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), manager));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        she.initialize(params());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(params());
        address admin =
            address(uint160(uint256(vm.load(address(she), bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)))));
        assertEq(ProxyAdmin(admin).owner(), upgradeGov);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
        vm.prank(manager);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(address(she)), address(implementation), "");
        bytes32 location =
            keccak256(abi.encode(uint256(keccak256("stHYPE.storage.StakedHypeEscrow")) - 1)) & ~bytes32(uint256(255));
        assertEq(location, 0xecd281f243c16ba7bca6e716285da9e177b38743a79560d95e19c9cd2cf92a00);
    }

    function test_rewardDurationRejectsZeroAndValuesAboveSevenDays() public {
        uint64[3] memory durations = [uint64(0), uint64(7 days + 1), type(uint64).max];
        for (uint256 i; i < durations.length; ++i) {
            I.InitializationParams memory p = params();
            p.configuration.rewardDuration = durations[i];
            vm.expectRevert(I.StakedHypeEscrow__InvalidConfiguration.selector);
            new TransparentUpgradeableProxy(
                address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (p))
            );
        }
    }

    function test_rewardDurationAcceptsOneSecondAndSevenDays() public {
        uint64[2] memory durations = [uint64(1), uint64(7 days)];
        for (uint256 i; i < durations.length; ++i) {
            I.InitializationParams memory p = params();
            p.configuration.rewardDuration = durations[i];
            StakedHypeEscrow escrow = StakedHypeEscrow(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (p))
                    )
                )
            );
            assertEq(abi.encode(escrow.configuration()), abi.encode(p.configuration));
            overseer.mint{value: 1 ether}(address(this));
            wrapper.approve(address(escrow), 1 ether);
            (uint256 units, uint256 accepted) = escrow.deposit(1 ether, alice, 1 ether * 1e6 - SEED, 1 ether);
            assertEq(units, 1 ether * 1e6 - SEED);
            assertEq(accepted, 1 ether);
            vm.prank(distributor);
            escrow.fundRewards{value: 1 ether}(1 ether * 1e6);
            (I.RewardStream memory stream, uint256 retained) = escrow.rewardState();
            assertEq(stream.start, block.timestamp);
            assertEq(stream.end, block.timestamp + durations[i]);
            assertEq(stream.totalRawShares, 1 ether * 1e6);
            assertEq(stream.releasedRawShares, 0);
            assertEq(retained, 0);
            assertEq(escrow.totalAccounting().rewardRawShares, 1 ether * 1e6);
            assertEq(escrow.totalAccounting().activeRawShares, 1 ether * 1e6);
            assertEq(escrow.totalAccounting().totalOwnershipUnits, 1 ether * 1e6);
            assertEq(token.sharesOf(address(escrow)), 2 ether * 1e6);
        }
    }

    function test_requestExcludesNewYieldThroughExecution() public {
        deposit(alice, 100 ether);
        deposit(bob, 100 ether);
        uint256 id = request(alice, 40 ether * 1e6);
        fund(16 ether);
        vm.warp(block.timestamp + 100);
        (, uint256 aa,) = she.account(alice);
        (, uint256 ba,) = she.account(bob);
        assertEq(aa, (60 ether * 1e6 - SEED) * 11 / 10);
        assertEq(ba, 110 ether * 1e6);
        assertEq(she.getWithdrawalRequest(id).rawShares, 40 ether * 1e6);
        vm.prank(alice);
        she.executeWithdrawal(id, 40 ether);
        assertEq(wrapper.balanceOf(alice), 40 ether);
        (, aa,) = she.account(alice);
        (, ba,) = she.account(bob);
        assertEq(aa, (60 ether * 1e6 - SEED) * 11 / 10);
        assertEq(ba, 110 ether * 1e6);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        assertEq(she.totalAccounting().rewardRawShares, 0);
        backed();
    }

    function test_emptyPoolRetainsPastEmissionsAndExplicitlyReschedules() public {
        uint256 id = request(bob, deposit(bob, 2));
        assertEq(she.totalAccounting().totalOwnershipUnits, SEED);
        assertEq(she.totalAccounting().activeRawShares, SEED);
        fund(10 ether);
        vm.warp(block.timestamp + 50);
        deposit(alice, 100 ether);
        (, uint256 retained) = she.rewardState();
        assertEq(retained, 5 ether * 1e6);
        vm.warp(block.timestamp + 50);
        she.checkpointRewards();
        (, uint256 aa,) = she.account(alice);
        assertEq(aa, uint256(100 ether * 1e6) * (105 ether * 1e6 + SEED) / (100 ether * 1e6 + SEED));
        assertEq(she.totalAccounting().rewardRawShares, 5 ether * 1e6);
        fund(1 ether);
        vm.warp(block.timestamp + 100);
        she.checkpointRewards();
        (, aa,) = she.account(alice);
        assertEq(aa, uint256(100 ether * 1e6) * (111 ether * 1e6 + SEED) / (100 ether * 1e6 + SEED));
        assertEq(she.totalAccounting().rewardRawShares, 0);
        executeAndAssertPayout(bob, id, 1);
        backed();
    }

    function test_emptyPoolDonationRetainedForFutureStream() public {
        donate(5 ether);
        assertEq(she.totalAccounting().activeRawShares, 0);
        assertEq(she.totalAccounting().rewardRawShares, 5 ether * 1e6);
        (, uint256 retained) = she.rewardState();
        assertEq(retained, 5 ether * 1e6);
        vm.expectRevert(I.StakedHypeEscrow__AccountingInvariant.selector);
        she.checkpointRewards();
        deposit(alice, 10 ether);
        (, uint256 aa,) = she.account(alice);
        assertEq(aa, 10 ether * 1e6 - SEED);
        assertEq(she.totalAccounting().rewardRawShares, 5 ether * 1e6);
        fund(1 ether);
        (I.RewardStream memory stream,) = she.rewardState();
        assertEq(stream.totalRawShares, 6 ether * 1e6);
        vm.warp(stream.end);
        she.checkpointRewards();
        (, aa,) = she.account(alice);
        assertEq(aa, (10 ether * 1e6 - SEED) * 16 / 10);
        assertEq(she.totalAccounting().rewardRawShares, 0);
        backed();
    }

    function test_donationBenefitsActiveUsersProRataAndExcludesQueuedShares() public {
        deposit(alice, 10 ether);
        deposit(bob, 30 ether);
        uint256 id = request(bob, 10 ether * 1e6);
        donate(3 ether);
        (, uint256 aa,) = she.account(alice);
        (, uint256 ba,) = she.account(bob);
        assertEq(aa, (10 ether * 1e6 - SEED) * 11 / 10);
        assertEq(ba, 22 ether * 1e6);
        assertEq(she.getWithdrawalRequest(id).rawShares, 10 ether * 1e6);
        assertEq(she.totalAccounting().totalOwnershipUnits, 30 ether * 1e6);
        assertEq(she.totalAccounting().rewardRawShares, 0);
        I.Accounting memory before = she.totalAccounting();
        vm.expectEmit(address(she));
        emitExpectedRewardsCheckpointed(3 ether * 1e6, 0);
        she.checkpointRewards();
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
        vm.recordLogs();
        she.checkpointRewards();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
        backed();
    }

    function test_depositPricesPreviouslyDonatedSharesForIncumbents() public {
        deposit(alice, 10 ether);
        donate(10 ether);
        (uint256 quoted, uint256 accepted,) = lens.previewDeposit(she, 10 ether);
        assertEq(quoted, 5 ether * 1e6);
        assertEq(accepted, 10 ether);
        assertEq(deposit(bob, 10 ether), quoted);
        (, uint256 aa,) = she.account(alice);
        (, uint256 ba,) = she.account(bob);
        assertEq(aa, (10 ether * 1e6 - SEED) * 2);
        assertEq(ba, 10 ether * 1e6);
        backed();
    }

    function test_newDepositsPreserveRequestsAndDoNotAuthorizeAnotherOwnerToCancel() public {
        deposit(alice, 10 ether);
        uint256 id = request(bob, deposit(bob, 10 ether));
        I.WithdrawalRequest memory original = she.getWithdrawalRequest(id);
        donate(10 ether);
        deposit(bob, 10 ether);
        (, uint256 aa,) = she.account(alice);
        (, uint256 ba,) = she.account(bob);
        assertEq(aa, (10 ether * 1e6 - SEED) * 2);
        assertEq(ba, 10 ether * 1e6);
        I.Accounting memory before = she.totalAccounting();
        (uint256 ownerUnits,,) = she.account(bob);
        for (uint256 i; i < 2; ++i) {
            if (i == 1) vm.warp(original.eligibleAt);
            vm.prank(alice);
            (bool success, bytes memory result) = address(she).call(abi.encodeCall(I.cancelWithdrawal, (id, 0)));
            assertFalse(success);
            assertEq(result, abi.encodeWithSelector(I.StakedHypeEscrow__OnlyRequestOwner.selector));
            assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(original));
            assertEq(abi.encode(she.totalAccounting()), abi.encode(before));
            (uint256 currentUnits,,) = she.account(bob);
            assertEq(currentUnits, ownerUnits);
            backed();
        }
        vm.prank(bob);
        she.executeWithdrawal(id, 10 ether);
        assertEq(wrapper.balanceOf(bob), 10 ether);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        (, aa,) = she.account(alice);
        (, ba,) = she.account(bob);
        assertEq(aa, (10 ether * 1e6 - SEED) * 2);
        assertEq(ba, 10 ether * 1e6);
        backed();
    }

    function test_requestRejectsSubWeiAndAcceptsExactlyOneWei() public {
        uint256 units = deposit(alice, 2);
        assertEq(units, 2e6 - SEED);
        assertRequestRejected(alice, 1e6 - 1, abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector));
        uint256 id = request(alice, 1e6);
        assertEq(id, 1);
        assertEq(she.getWithdrawalRequest(id).rawShares, 1e6);
        assertEq(she.totalAccounting().requestedRawShares, 1e6);
        executeAndAssertPayout(alice, id, 1);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(she.totalAccounting().activeRawShares, 1e6);
        assertEq(she.totalAccounting().totalOwnershipUnits, 1e6);
        (uint256 remaining,,) = she.account(alice);
        assertEq(remaining, 1e6 - SEED);
    }

    function test_requestAcceptsFormerCapAndAboveInSingleWithdrawal() public {
        // A separate seed payer makes the former boundary exact, without seed rounding.
        deposit(bob, 2);
        uint256[3] memory amounts = [uint256(200_000_000e18), uint256(200_000_000e18 + 1), uint256(500_000_000e18)];
        assertGt(amounts[2], type(uint88).max);
        uint256 paid;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            vm.deal(address(this), amount);
            uint256 units = deposit(alice, amount);
            assertEq(units, amount * 1e6);
            assertEq(token.sharesToBalance(units), amount);
            assertEq(lens.previewRequestWithdrawal(she, alice, units), units);
            assertEq(
                abi.encode(she.totalAccounting()),
                abi.encode(I.Accounting((amount + 2) * 1e6, (amount + 2) * 1e6, 0, 0))
            );
            I.Accounting memory expected = I.Accounting(2e6, 2e6, units, 0);
            vm.expectEmit(address(she));
            emit I.WithdrawalRequested(
                i + 1, alice, units, units, uint64(block.timestamp + 10), I.AccountBalance(0, 0), expected
            );
            uint256 id = request(alice, units);
            assertEq(id, i + 1);
            assertEq(
                abi.encode(she.getWithdrawalRequest(id)),
                abi.encode(
                    I.WithdrawalRequest(
                        alice, units, uint64(block.timestamp), uint64(block.timestamp + 10), I.RequestStatus.REQUESTED
                    )
                )
            );
            assertEq(abi.encode(she.totalAccounting()), abi.encode(expected));
            assertEq(token.sharesOf(address(she)), (amount + 2) * 1e6);
            assertEq(wrapper.balanceOf(alice), paid);
            (uint256 remaining, uint256 active,) = she.account(alice);
            assertEq(remaining, 0);
            assertEq(active, 0);
            (bool eligible, uint256 quote) = lens.previewExecution(she, id);
            assertFalse(eligible);
            assertEq(quote, amount);
            backed();
            vm.expectEmit(address(she));
            emitExpectedWithdrawalExecuted(id, amount);
            executeAndAssertPayout(alice, id, amount);
            paid += amount;
            assertEq(wrapper.balanceOf(alice), paid);
            assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(2e6, 2e6, 0, 0)));
            (uint256 seedUnits, uint256 seedRaw,) = she.account(she.SEED_OWNER());
            assertEq(seedUnits, SEED);
            assertEq(seedRaw, SEED);
            (uint256 bobUnits, uint256 bobRaw,) = she.account(bob);
            assertEq(bobUnits, 2e6 - SEED);
            assertEq(bobRaw, 2e6 - SEED);
        }
    }

    function test_requestAboveFormerCapIncludesRewardsAndMinimumFailureRollsBackCheckpoint() public {
        uint256 amount = 200_000_000e18;
        vm.deal(address(this), amount);
        uint256 units = deposit(alice, amount);
        fund(2);
        (I.RewardStream memory stream,) = she.rewardState();
        vm.warp(stream.end);
        uint256 raw = (amount + 2) * 1e6 - SEED - 1;
        assertEq(she.totalAccounting().activeRawShares, (amount + 2) * 1e6);
        assertEq(token.sharesToBalance(raw), amount + 1);
        bytes memory before = requestAdmissionState(alice);
        vm.expectRevert(abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector));
        vm.prank(alice);
        she.requestWithdrawal(units, raw + 1);
        assertEq(requestAdmissionState(alice), before);
        // A reverted request must not consume the pending reward checkpoint.
        vm.expectEmit(address(she));
        emitExpectedRewardsCheckpointed(2e6, 0);
        vm.prank(alice);
        uint256 id = she.requestWithdrawal(units, raw);
        assertEq(id, 1);
        assertEq(she.getWithdrawalRequest(id).rawShares, raw);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(SEED + 1, SEED, raw, 0)));
        executeAndAssertPayout(alice, id, amount + 1);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(SEED + 1, SEED, 0, 1e6 - SEED - 1)));
        assertEq(wrapper.balanceOf(alice), amount + 1);
    }

    function test_requestMinimumUsesCurrentSlashedValue() public {
        uint256 units = deposit(alice, 4);
        overseer.setMaxSlashPercentage(0.5e18);
        vm.warp(block.timestamp + 1);
        vm.deal(address(overseer), address(overseer).balance / 2);
        overseer.rebase();
        assertEq(token.sharesToBalance(1e6), 0);
        assertEq(token.sharesToBalance(units), 1);
        assertRequestRejected(alice, 1e6, abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector));
        uint256 id = request(alice, units);
        assertEq(id, 1);
        assertEq(she.getWithdrawalRequest(id).rawShares, 4e6 - SEED);
        executeAndAssertPayout(alice, id, 3);
        assertEq(she.totalAccounting().requestedRawShares, 0);
    }

    function test_requestAcceptsRebasedValueAboveFormerCap() public {
        uint256 amount = 100_000_000e18 + 1;
        vm.deal(address(this), amount);
        uint256 units = deposit(alice, amount);
        uint256 newSupply = token.totalSupply() * 2;
        vm.deal(address(overseer), newSupply);
        token.syncSupply(newSupply, 0); // Exercise the real token conversion at twice the initial value.
        assertEq(token.sharesToBalance(units), amount * 2 - 1);
        uint256 id = request(alice, units);
        assertEq(id, 1);
        assertEq(she.getWithdrawalRequest(id).rawShares, units);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(SEED, SEED, units, 0)));
        executeAndAssertPayout(alice, id, amount - 1);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(SEED, SEED, 0, 1e6 - SEED)));
        (uint256 remaining, uint256 active,) = she.account(alice);
        assertEq(remaining, 0);
        assertEq(active, 0);
    }

    function test_largePositionCanStillSplitIntoIndependentRequests() public {
        uint256 amount = 500_000_000e18;
        vm.deal(address(this), amount);
        uint256 units = deposit(alice, amount);
        uint256[3] memory amounts = [uint256(300_000_000e18), uint256(100_000_000e18), uint256(100_000_000e18)];
        uint256 start = block.timestamp;
        uint256 reserved;
        for (uint256 i; i < amounts.length; ++i) {
            vm.warp(start + i);
            uint256 raw = amounts[i] * 1e6 - (i == 2 ? SEED : 0);
            uint256 id = request(alice, raw);
            assertEq(id, i + 1);
            I.WithdrawalRequest memory withdrawal = she.getWithdrawalRequest(id);
            assertEq(withdrawal.owner, alice);
            assertEq(withdrawal.rawShares, raw);
            assertEq(withdrawal.requestedAt, start + i);
            assertEq(withdrawal.eligibleAt, start + i + 10);
            assertEq(uint256(withdrawal.status), uint256(I.RequestStatus.REQUESTED));
            reserved += raw;
            I.Accounting memory accounting = she.totalAccounting();
            assertEq(accounting.requestedRawShares, reserved);
            assertEq(accounting.activeRawShares, units + SEED - reserved);
            assertEq(accounting.totalOwnershipUnits, units + SEED - reserved);
            assertEq(accounting.rewardRawShares, 0);
            (uint256 remaining,,) = she.account(alice);
            assertEq(remaining, units - reserved);
            backed();
        }
        bytes memory first = abi.encode(she.getWithdrawalRequest(1));
        bytes memory third = abi.encode(she.getWithdrawalRequest(3));
        executeAndAssertPayout(alice, 2, amounts[1]);
        assertEq(abi.encode(she.getWithdrawalRequest(1)), first);
        assertEq(abi.encode(she.getWithdrawalRequest(3)), third);
        assertEq(she.totalAccounting().requestedRawShares, 400_000_000e18 * 1e6 - SEED);
        executeAndAssertPayout(alice, 1, amounts[0]);
        assertEq(she.totalAccounting().requestedRawShares, amounts[2] * 1e6 - SEED);
        executeAndAssertPayout(alice, 3, amounts[2] - 1);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(wrapper.balanceOf(alice), amount - 1);
        assertEq(she.totalAccounting().activeRawShares, SEED);
        assertEq(she.totalAccounting().totalOwnershipUnits, SEED);
    }

    function test_requestCanExecuteAfterAppreciatingAboveTwoHundredMillion() public {
        uint256 maximum = 200_000_000e18;
        vm.deal(address(this), maximum * 2);
        uint256 units = deposit(alice, maximum);
        deposit(bob, maximum);
        uint256 id = request(alice, units);
        // Appreciation changes nominal value, while the reserved wstHYPE amount is fixed.
        uint256 newSupply = token.totalSupply() * 5 / 4;
        vm.deal(address(overseer), newSupply);
        token.syncSupply(newSupply, 0);
        assertEq(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), 250_000_000e18 - 1);
        executeAndAssertPayout(alice, id, maximum - 1);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        (uint256 remaining, uint256 active,) = she.account(bob);
        assertEq(remaining, units + SEED);
        assertEq(active, maximum * 1e6 + (1e6 - SEED) * (maximum * 1e6) / (maximum * 1e6 + SEED));
        assertEq(token.sharesToBalance(active), 250_000_000e18 + 1);
    }

    function test_seedBoundsSingleUnitAfterLargeDonationAndPreservesLockedBacking() public {
        uint256 donation = 999_999_999e18;
        vm.deal(address(this), donation + 2);
        uint256 units = deposit(alice, 2);
        uint256 oldRequest = request(alice, units - 1);
        donate(donation);
        uint256 pool = donation * 1e6 + SEED + 1;
        uint256 expected = pool / (SEED + 1);
        (uint256 remaining, uint256 active,) = she.account(alice);
        assertEq(remaining, 1);
        assertEq(active, expected);
        assertLt(token.totalSupply(), 1_000_000_000e18);
        assertLe(token.sharesToBalance(active), 1_000_000e18);
        uint256 id = request(alice, 1);
        assertEq(id, oldRequest + 1);
        assertEq(she.getWithdrawalRequest(id).rawShares, expected);
        executeAndAssertPayout(alice, id, expected / 1e6);
        executeAndAssertPayout(alice, oldRequest, 1);
        I.Accounting memory accounting = she.totalAccounting();
        uint256 dust = expected % 1e6 + (1e6 - SEED - 1);
        assertEq(accounting.totalOwnershipUnits, SEED);
        assertEq(accounting.activeRawShares, pool - expected);
        assertEq(accounting.requestedRawShares, 0);
        assertEq(accounting.rewardRawShares, dust);
        assertEq(token.sharesOf(address(she)), pool - expected + dust);
        assertEq(wrapper.balanceOf(alice), expected / 1e6 + 1);
    }

    function test_maturityInclusiveAndExactMinimumErrors() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        I.WithdrawalRequest memory w = she.getWithdrawalRequest(id);
        vm.warp(w.eligibleAt - 1);
        vm.expectRevert(I.StakedHypeEscrow__CooldownNotElapsed.selector);
        vm.prank(alice);
        she.executeWithdrawal(id, 0);
        vm.warp(w.eligibleAt);
        vm.expectRevert(I.StakedHypeEscrow__MinimumNotMet.selector);
        vm.prank(bob);
        she.executeWithdrawal(id, 10 ether);
        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertEq(wrapper.balanceOf(bob), 0);
        vm.expectRevert(I.StakedHypeEscrow__InvalidRequest.selector);
        vm.prank(alice);
        she.executeWithdrawal(id, 0);
        backed();
    }

    function test_globalPauseBlocksUserAssetOperationsAndPreservesRequest() public {
        uint256 u = deposit(alice, 10 ether);
        uint256 id = request(alice, u / 2);
        I.WithdrawalRequest memory original = she.getWithdrawalRequest(id);
        overseer.mint{value: 10 ether}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 10 ether);
        vm.prank(manager);
        she.setPaused(true);
        vm.warp(original.eligibleAt);
        vm.expectRevert(I.StakedHypeEscrow__Paused.selector);
        vm.prank(alice);
        she.executeWithdrawal(id, 0);
        vm.expectRevert(I.StakedHypeEscrow__Paused.selector);
        vm.prank(alice);
        she.requestWithdrawal(u / 2, 0);
        vm.expectRevert(I.StakedHypeEscrow__Paused.selector);
        vm.prank(bob);
        she.deposit(10 ether, bob, 1, 10 ether);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(original));
        assertEq(she.totalAccounting().requestedRawShares, u / 2);
        assertEq(she.totalAccounting().activeRawShares, 5 ether * 1e6 + SEED / 2);
        backed();
        vm.prank(manager);
        she.setPaused(false);
        vm.prank(bob);
        she.deposit(10 ether, bob, 1, 10 ether);
        vm.prank(alice);
        she.executeWithdrawal(id, 5 ether - 1);
        assertEq(wrapper.balanceOf(alice), 5 ether - 1);
        assertEq(she.getWithdrawalRequest(id).eligibleAt, original.eligibleAt);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.EXECUTED));
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(she.totalAccounting().activeRawShares, (15 ether + 1) * 1e6);
        assertEq(she.totalAccounting().totalOwnershipUnits, 15 ether * 1e6 + SEED / 2);
        backed();
    }

    function test_wstHypeTransferDoesNotCallOwnerReceive() public {
        LockObservingRecipient receiver = new LockObservingRecipient(I(address(she)));
        uint256 id = request(address(receiver), deposit(address(receiver), 10 ether));
        executeAndAssertPayout(address(receiver), id, 10 ether - 1);
        assertEq(receiver.callbackCount(), 0);
        assertFalse(receiver.observedLocked());
        assertFalse(she.isLocked());
    }

    function test_isLockedRemainsFalseDuringOwnerChosenRedemption() public {
        LockObservingRecipient receiver = new LockObservingRecipient(I(address(she)));
        uint256 id = request(address(receiver), deposit(address(receiver), 10 ether));
        executeAndAssertPayout(address(receiver), id, 10 ether - 1);
        vm.prank(address(receiver));
        uint256 burn = overseer.burn(address(receiver), 10 ether - 1);
        overseer.redeem(burn);
        assertEq(receiver.callbackCount(), 1);
        assertFalse(receiver.observedLocked());
        assertFalse(she.isLocked());
        assertEq(address(receiver).balance, 10 ether - 1);
        assertEq(wrapper.balanceOf(address(receiver)), 0);
        backed();
    }

    function test_ownerRejectingNativeHypeCanReceiveWstHype() public {
        RejectingRecipient receiver = new RejectingRecipient();
        uint256 id = request(address(receiver), deposit(address(receiver), 10 ether));
        executeAndAssertPayout(address(receiver), id, 10 ether - 1);
        assertEq(address(receiver).balance, 0);
    }

    function test_ownerCanDonateReturnedWstHypeToActiveUsers() public {
        deposit(bob, 5 ether);
        uint256 id = request(alice, deposit(alice, 2 ether));
        uint256 queued = request(bob, 1 ether * 1e6);
        fund(4 ether);
        executeAndAssertPayout(alice, id, 2 ether);
        I.Accounting memory before = she.totalAccounting();
        vm.prank(alice);
        assertTrue(wrapper.transfer(address(she), 1 ether));
        she.checkpointRewards();
        assertEq(she.totalAccounting().activeRawShares, before.activeRawShares + 1 ether * 1e6);
        assertEq(she.totalAccounting().rewardRawShares, before.rewardRawShares);
        assertEq(she.getWithdrawalRequest(queued).rawShares, 1 ether * 1e6);
        assertEq(wrapper.balanceOf(alice), 1 ether);
        backed();
    }

    function test_withdrawalRoundingBenefitsRemainingActiveUsers() public {
        uint256 units = deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        fund(1);
        vm.warp(block.timestamp + 100);
        uint256 id = request(alice, units);
        assertEq(
            she.getWithdrawalRequest(id).rawShares, (10 ether * 1e6 - SEED) * (20 ether * 1e6 + 1e6) / (20 ether * 1e6)
        );
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        vm.prank(alice);
        she.executeWithdrawal(id, 10 ether);
        assertEq(wrapper.balanceOf(alice), 10 ether);
        (uint256 au, uint256 aa,) = she.account(alice);
        (, uint256 ba,) = she.account(bob);
        assertEq(au, 0);
        assertEq(aa, 0);
        assertEq(ba, uint256(10 ether * 1e6) * (10 ether * 1e6 + 1e6) / (10 ether * 1e6 + SEED));
        assertEq(she.totalAccounting().rewardRawShares, 0);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(token.sharesOf(address(she)), 10 ether * 1e6 + 1e6);
        backed();
    }

    function test_emptyPoolWithdrawalRoundingRetainedInRewardReserve() public {
        uint256 au = deposit(alice, 10 ether);
        uint256 bu = deposit(bob, 10 ether);
        fund(1);
        vm.warp(block.timestamp + 100);
        uint256 pool = 20 ether * 1e6 + 1e6;
        uint256 aliceRaw = au * pool / (20 ether * 1e6);
        uint256 bobRaw = bu * (pool - aliceRaw) / (bu + SEED);
        uint256 aid = request(alice, au);
        uint256 bid = request(bob, bu);
        assertEq(she.getWithdrawalRequest(aid).rawShares, aliceRaw);
        assertEq(she.getWithdrawalRequest(bid).rawShares, bobRaw);
        executeAndAssertPayout(alice, aid, aliceRaw / 1e6);
        assertEq(she.totalAccounting().rewardRawShares, aliceRaw % 1e6);
        executeAndAssertPayout(bob, bid, bobRaw / 1e6);
        uint256 locked = pool - aliceRaw - bobRaw;
        uint256 retained = aliceRaw % 1e6 + bobRaw % 1e6;
        assertEq(she.totalAccounting().activeRawShares, locked);
        assertEq(she.totalAccounting().totalOwnershipUnits, SEED);
        assertEq(she.totalAccounting().requestedRawShares, 0);
        assertEq(she.totalAccounting().rewardRawShares, retained);
        uint256 fresh = deposit(alice, 1 ether);
        assertEq(fresh, uint256(1 ether * 1e6) * SEED / locked);
        (, uint256 aa,) = she.account(alice);
        assertEq(aa, fresh * (locked + 1 ether * 1e6) / (SEED + fresh));
        assertEq(she.totalAccounting().rewardRawShares, retained);
        backed();
    }

    function test_ownerDonationAfterExitRetainedInEmptyPoolReserve() public {
        uint256 id = request(alice, deposit(alice, 2 ether));
        executeAndAssertPayout(alice, id, 2 ether - 1);
        vm.prank(alice);
        assertTrue(wrapper.transfer(address(she), 1 ether));
        she.checkpointRewards();
        assertEq(she.totalAccounting().activeRawShares, SEED);
        assertEq(she.totalAccounting().rewardRawShares, (1 ether + 1) * 1e6 - SEED);
        deposit(bob, 1 ether);
        assertEq(she.totalAccounting().rewardRawShares, (1 ether + 1) * 1e6 - SEED);
        backed();
    }

    function test_upstreamBurnAndRedemptionPausesDoNotBlockTransfer() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        overseer.pauseRedemptionAndBurns();
        token.pauseBurn(true);
        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertTrue(overseer.isBurningPaused());
        assertTrue(overseer.isRedemptionPaused());
    }

    function test_transferDoesNotRequirePreSyncSupplyRefresh() public {
        uint256 id = request(alice, deposit(alice, 1 ether));
        uint256 newSupply = token.totalSupply() * 11 / 10;
        vm.deal(address(overseer), newSupply);
        token.syncSupply(newSupply, 20);
        vm.warp(token.syncEnd() + 1);
        assertGt(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), token.preSyncSupply());
        executeAndAssertPayout(alice, id, 1 ether - 1);
    }

    function test_failedFundingDoesNotBlockEligibleWithdrawal() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        token.pauseMint(true);
        vm.expectRevert(stHYPE.MintIsPaused.selector);
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(0);
        assertEq(she.totalAccounting().rewardRawShares, 0);
        (I.RewardStream memory stream,) = she.rewardState();
        assertEq(stream.end, 0);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        vm.prank(alice);
        she.executeWithdrawal(id, 10 ether - 1);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
        backed();
    }

    function test_depositCounterexampleChargesOnlyIssuedEntitlement() public {
        // Leave one user unit plus the permanent seed, then make each unit worth 100 wstHYPE.
        uint256 u = deposit(alice, 2);
        request(alice, u - 1);
        vm.deal(distributor, 100 ether * (SEED + 1));
        fund(100 ether * (SEED + 1));
        vm.warp(block.timestamp + 100);
        overseer.mint{value: 199 ether}(bob);
        vm.startPrank(bob);
        wrapper.approve(address(she), 199 ether);
        vm.expectCall(
            address(she), abi.encodeCall(I.quoteEntry, (199 ether * 1e6, (100 ether * 1e6 + 1) * (SEED + 1), SEED + 1))
        );
        (uint256 n, uint256 accepted, uint256 unspent) = lens.previewDeposit(she, 199 ether);
        assertEq(n, 1);
        assertEq(accepted, 100 ether + 1);
        assertEq(unspent, 99 ether - 1);
        uint256 held = token.sharesOf(address(she));
        vm.expectRevert(I.StakedHypeEscrow__MinimumNotMet.selector);
        she.deposit(199 ether, bob, n, 199 ether);
        assertEq(wrapper.balanceOf(bob), 199 ether);
        assertEq(token.sharesOf(address(she)), held);
        (uint256 actualUnits, uint256 actualCharge) = she.deposit(199 ether, bob, n, accepted);
        vm.stopPrank();
        assertEq(actualUnits, n);
        assertEq(actualCharge, accepted);
        assertEq(wrapper.balanceOf(bob), unspent);
        assertEq(token.sharesOf(address(she)), held + accepted * 1e6);
        (, uint256 incumbent,) = she.account(alice);
        assertLt(incumbent - (100 ether * 1e6 + 1), 1e6);
        backed();
    }

    function test_activeFundingRejectedAndMinAppliesOnlyToNewShares() public {
        request(bob, deposit(bob, 2)); // Retain emissions in a bootstrapped seed-only pool.
        fund(10 ether);
        vm.warp(block.timestamp + 50);
        vm.expectRevert(I.StakedHypeEscrow__StreamActive.selector);
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(0);
        assertEq(she.totalAccounting().rewardRawShares, 10 ether * 1e6);
        vm.warp(block.timestamp + 50);
        vm.expectRevert(I.StakedHypeEscrow__MinimumNotMet.selector);
        vm.prank(distributor);
        she.fundRewards{value: 1 ether}(1 ether * 1e6 + 1);
        (I.RewardStream memory previous, uint256 retained) = she.rewardState();
        assertEq(retained, 10 ether * 1e6);
        fund(1 ether);
        (I.RewardStream memory next,) = she.rewardState();
        assertEq(next.totalRawShares, retained + 1 ether * 1e6);
        assertEq(next.start, previous.end);
        assertEq(next.end, next.start + 100);
        backed();
    }

    function test_zeroFundingRejectedWithoutReserve() public {
        vm.expectRevert(I.StakedHypeEscrow__InvalidAmount.selector);
        vm.prank(distributor);
        she.fundRewards(0);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(stream.totalRawShares, 0);
        assertEq(stream.end, 0);
        assertEq(retained, 0);
        assertEq(she.totalAccounting().rewardRawShares, 0);
        assertEq(token.sharesOf(address(she)), 0);
        backed();
    }

    function test_zeroFundingCannotRescheduleRetainedReserve() public {
        request(bob, deposit(bob, 2));
        fund(10 ether);
        vm.warp(block.timestamp + 100);
        (I.RewardStream memory previous, uint256 retained) = she.rewardState();
        assertEq(retained, 10 ether * 1e6);
        I.Accounting memory accountingBefore = she.totalAccounting();
        uint256 held = token.sharesOf(address(she));
        uint256 supply = token.totalSupply();
        uint256 hypeBalance = address(overseer).balance;
        vm.expectRevert(I.StakedHypeEscrow__InvalidAmount.selector);
        vm.prank(distributor);
        she.fundRewards(0);
        (I.RewardStream memory next, uint256 retainedAfter) = she.rewardState();
        assertEq(abi.encode(next), abi.encode(previous));
        assertEq(retainedAfter, retained);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(accountingBefore));
        assertEq(token.sharesOf(address(she)), held);
        assertEq(token.totalSupply(), supply);
        assertEq(address(overseer).balance, hypeBalance);
        backed();
    }

    function test_oneWeiFundingStartsBackedStream() public {
        deposit(alice, 2);
        uint256 hypeBalance = address(overseer).balance;
        fund(1);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(stream.totalRawShares, 1e6);
        assertEq(stream.releasedRawShares, 0);
        assertEq(stream.start, block.timestamp);
        assertEq(stream.end, block.timestamp + 100);
        assertEq(retained, 0);
        assertEq(she.totalAccounting().rewardRawShares, 1e6);
        assertEq(she.totalAccounting().activeRawShares, 2e6);
        assertEq(she.totalAccounting().totalOwnershipUnits, 2e6);
        assertEq(token.sharesOf(address(she)), 3e6);
        assertEq(address(overseer).balance, hypeBalance + 1);
        backed();
    }

    function testFuzz_donationAllocationConservesShares(uint64 a, uint64 b, uint64 d) public {
        uint256 aliceUnits = deposit(alice, uint256(a) + 2);
        uint256 bobUnits = deposit(bob, uint256(b) + 2);
        uint256 queued = bobUnits / 2;
        uint256 bid = request(bob, queued);
        donate(uint256(d) + 1);
        uint256 units = aliceUnits + bobUnits + SEED - queued;
        uint256 active = units + (uint256(d) + 1) * 1e6;
        uint256 aliceShares = aliceUnits * active / units;
        {
            I.Accounting memory accounting = she.totalAccounting();
            assertEq(accounting.activeRawShares, active);
            assertEq(accounting.totalOwnershipUnits, units);
            assertEq(accounting.requestedRawShares, queued);
            assertEq(accounting.rewardRawShares, 0);
            (, uint256 aa,) = she.account(alice);
            (, uint256 ba,) = she.account(bob);
            (, uint256 locked,) = she.account(address(1));
            assertEq(aa, aliceShares);
            assertEq(ba, (bobUnits - queued) * active / units);
            assertEq(locked, SEED * active / units);
            assertLe(aa + ba + locked, active);
            assertLe(active - aa - ba - locked, 2);
            she.checkpointRewards();
            assertEq(abi.encode(she.totalAccounting()), abi.encode(accounting));
        }
        assertEq(she.getWithdrawalRequest(bid).rawShares, queued);
        assertEq(she.getWithdrawalRequest(request(alice, aliceUnits)).rawShares, aliceShares);
        uint256 bobShares = (bobUnits - queued) * (active - aliceShares) / (units - aliceUnits);
        assertEq(she.getWithdrawalRequest(request(bob, bobUnits - queued)).rawShares, bobShares);
        uint256 seedAssets = active - aliceShares - bobShares;
        assertEq(she.totalAccounting().activeRawShares, seedAssets);
        assertEq(she.totalAccounting().totalOwnershipUnits, SEED);
        assertEq(she.totalAccounting().requestedRawShares, queued + aliceShares + bobShares);
        donate(1);
        she.checkpointRewards();
        assertEq(she.totalAccounting().rewardRawShares, 1e6);
        backed();
    }

    function testFuzz_depositQuoteBound(uint96 ar, uint96 ur, uint96 mr) public view {
        uint256 a = uint256(ar) + 1;
        uint256 u = uint256(ur) + 1;
        uint256 g = 1e6;
        uint256 offered = (uint256(mr) + 1) * g;
        (uint256 n, uint256 charged) = she.quoteEntry(offered, a, u);
        assertEq(n, offered * u / a);
        if (n == 0) {
            assertEq(charged, 0);
            return;
        }
        assertLe(charged, offered);
        assertEq(charged % g, 0);
        // Exact rational numerator, independent of entry implementation rounding.
        assertGe(charged * u, n * a);
        assertLt(charged * u - n * a, g * u);
        assertLt((charged - g) * u, n * a); // smallest transferable multiple covering the issued entitlement
    }
}
