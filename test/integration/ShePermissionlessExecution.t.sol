// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {RejectingRecipient} from "../helpers/SheTestBase.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";

contract SheWithdrawalExecutor {
    function execute(I escrow, uint256 id, uint256 minimum) external returns (uint256) {
        return escrow.executeWithdrawal(id, minimum);
    }
}

contract ShePermissionlessExecutionTest is SheAssertions {
    SheWithdrawalExecutor keeper;
    address stranger = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        keeper = new SheWithdrawalExecutor();
        extraActors.push(address(keeper));
        extraActors.push(stranger);
    }

    // First validate the owner path using independent exact payout/accounting assertions.
    // Restore the same state, execute as a third party, and compare every field in the
    // broad snapshot, including all request records, owner/caller wallets and allowances.
    function assertPermissionlessPayout(address executor, uint256 id, uint256 minimum) internal {
        I.WithdrawalRequest memory withdrawal = she.getWithdrawalRequest(id);
        assertNotEq(executor, withdrawal.owner);
        vm.warp(withdrawal.eligibleAt > block.timestamp ? withdrawal.eligibleAt : block.timestamp);
        uint256 amount = withdrawal.rawShares / 1e6;
        uint256 ownerBalance = wrapper.balanceOf(withdrawal.owner);
        uint256 ownerRaw = token.sharesOf(withdrawal.owner);
        uint256 callerRaw = token.sharesOf(executor);
        uint256 saved = vm.snapshot();
        executeAndAssertPayout(withdrawal.owner, id, amount);
        bytes32 expected = snapshot();
        assertTrue(vm.revertToAndDelete(saved));

        vm.expectEmit(address(she));
        emitExpectedWithdrawalExecuted(id, amount);
        uint256 actual;
        if (executor == address(keeper)) {
            actual = keeper.execute(she, id, minimum);
        } else {
            vm.prank(executor);
            actual = she.executeWithdrawal(id, minimum);
        }
        assertEq(actual, amount);
        assertEq(wrapper.balanceOf(withdrawal.owner), ownerBalance + amount);
        assertEq(token.sharesOf(withdrawal.owner), ownerRaw + amount * 1e6);
        assertEq(token.sharesOf(executor), callerRaw, "executor received owner shares");
        assertEq(snapshot(), expected, "third-party settlement differs from verified owner settlement");
        backed();
    }

    function test_strangerExecutesAtExactMaturityAndPaysFullAmountWithZeroMinimum() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        assertPermissionlessPayout(stranger, id, 0);
        assertEq(block.timestamp, she.getWithdrawalRequest(id).eligibleAt);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
        assertEq(storedAccounting().rewardRawShares, 1e6 - SEED);
    }

    function test_contractExecutorPreservesRewardsDustAndOtherPendingRequest() public {
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        uint256 id = request(alice, 6 ether * 1e6 + 123);
        uint256 other = request(bob, 2 ether * 1e6);
        bytes memory otherBefore = abi.encode(she.getWithdrawalRequest(other));
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether);
        assertEq(she.getWithdrawalRequest(id).rawShares % 1e6, 123);
        assertPermissionlessPayout(address(keeper), id, 6 ether);
        assertEq(abi.encode(she.getWithdrawalRequest(other)), otherBefore);
    }

    function test_contractOwnerReceivesTokensWithoutApprovalOrRecipientCallback() public {
        address owner = address(new RejectingRecipient());
        extraActors.push(owner);
        uint256 id = request(owner, deposit(owner, 10 ether));
        assertEq(wrapper.allowance(owner, address(she)), 0);
        assertPermissionlessPayout(address(keeper), id, 0);
        assertEq(wrapper.balanceOf(owner), 10 ether - 1);
        assertEq(owner.balance, 0);
    }

    function test_thirdPartyFailuresPreserveAllStateAndAllowRetry() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        deposit(bob, 10 ether);
        fund(2 ether);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt - 1);
        donate(1 ether);
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id + 1, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        she.setPaused(true);
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector)
        );
        vm.prank(manager);
        she.setPaused(false);
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 10 ether)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        token.pauseTransfer(true);
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(stHYPE.TransferIsPaused.selector)
        );
        token.pauseTransfer(false);
        assertPermissionlessPayout(stranger, id, 0);
    }

    function test_executionFirstPreventsCancellationAndDoublePayment() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        assertPermissionlessPayout(stranger, id, 0);
        reject(
            alice,
            0,
            abi.encodeCall(I.cancelWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
    }

    function test_ownerCancellationFirstPreventsThirdPartyPayment() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        reject(
            stranger,
            0,
            abi.encodeCall(I.cancelWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__OnlyRequestOwner.selector)
        );
        vm.prank(alice);
        she.cancelWithdrawal(id, 1);
        assertEq(uint256(she.getWithdrawalRequest(id).status), uint256(I.RequestStatus.CANCELLED));
        reject(
            stranger,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
        assertEq(wrapper.balanceOf(alice), 0);
        assertEq(wrapper.balanceOf(stranger), 0);
        backed();
    }

    function testFuzz_arbitraryExecutorAndMinimumCannotReduceOrRedirectPayout(
        address executor,
        uint96 amountSeed,
        uint96 unitsSeed,
        uint96 minimumSeed
    ) public {
        vm.assume(executor != address(0) && executor != address(1) && executor != alice);
        vm.assume(executor.code.length == 0);
        extraActors.push(executor);
        uint256 units = deposit(alice, bound(uint256(amountSeed), 1 ether, 100 ether));
        deposit(bob, 10 ether);
        uint256 id = request(alice, bound(uint256(unitsSeed), 1e6, units));
        uint256 amount = she.getWithdrawalRequest(id).rawShares / 1e6;
        assertPermissionlessPayout(executor, id, bound(uint256(minimumSeed), 0, amount));
    }
}
