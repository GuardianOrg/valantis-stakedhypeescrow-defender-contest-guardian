// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {SheTransferDeltaWrapper} from "./SheDependency.t.sol";
import {SheRescueToken} from "./SheRescue.t.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract SheGuardedConsumer {
    error EscrowLocked();
    I immutable escrow;

    constructor(I escrow_) {
        escrow = escrow_;
    }

    function activeAssets() external view returns (uint256) {
        if (escrow.isLocked()) revert EscrowLocked();
        return escrow.totalAccounting().activeRawShares;
    }
}

contract SheReentrantRecipient {
    I immutable escrow;
    SheGuardedConsumer immutable consumer;
    bytes action;
    uint256 actionValue;
    // Fault-injected wrapper callbacks exercise the guard; the supported wrapper has no recipient hook.
    uint64 public callbackCount;
    bool public observedLocked;
    bool public actionSucceeded;
    bool public consumerRejected;
    bytes4 public actionError;
    bytes32 public actionResultHash;

    constructor(I escrow_, SheGuardedConsumer consumer_) {
        escrow = escrow_;
        consumer = consumer_;
    }

    function configure(bytes calldata action_, uint256 value_) external {
        action = action_;
        actionValue = value_;
    }

    function onTransfer() external {
        bool locked = escrow.isLocked();
        (bool success, bytes memory result) = address(escrow).call{value: actionValue}(action);
        (bool readSuccess, bytes memory readResult) =
            address(consumer).staticcall(abi.encodeCall(SheGuardedConsumer.activeAssets, ()));
        callbackCount++;
        observedLocked = locked;
        actionSucceeded = success;
        actionError = bytes4(result);
        actionResultHash = keccak256(result);
        consumerRejected = !readSuccess
            && keccak256(readResult) == keccak256(abi.encodeWithSelector(SheGuardedConsumer.EscrowLocked.selector));
    }
}

// A deliberately callback-capable dependency, with real token custody and explicit wrapper authority.
contract SheCallbackWrapper is SheTransferDeltaWrapper {
    SheReentrantRecipient public callback;
    constructor(stHYPE token) SheTransferDeltaWrapper(token) {}

    function setCallback(SheReentrantRecipient recipient) external {
        callback = recipient;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        sthype.transferShares(msg.sender, to, amount * 1e6);
        callback.onTransfer();
        return true;
    }
}

contract SheReentrancyTest is SheAssertions {
    SheRescueToken private rescueToken;

    function installCallbackWrapper() private returns (SheCallbackWrapper fault) {
        fault = new SheCallbackWrapper(token);
        wrapper = wstHYPE(address(fault));
        token.grantRole(token.WRAPPER_ROLE(), address(fault));
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(I.initialize, (params()))
                )
            )
        );
    }

    function test_inheritedGovernanceRemainsAuthorizedWhileEscrowLocked() public {
        for (uint256 operation; operation < 3; ++operation) {
            uint256 state = vm.snapshot();
            SheCallbackWrapper fault = installCallbackWrapper();
            SheGuardedConsumer consumer = new SheGuardedConsumer(she);
            SheReentrantRecipient receiver = new SheReentrantRecipient(she, consumer);
            address recipient = address(receiver);
            she.grantRole(she.MANAGER_ROLE(), recipient);
            deposit(alice, 10 ether);
            uint256 id = request(alice, 6 ether * 1e6);
            I.WithdrawalRequest memory expected = she.getWithdrawalRequest(id);
            bytes memory action;
            if (operation == 0) action = abi.encodeCall(IAccessControl.renounceRole, (she.MANAGER_ROLE(), recipient));
            if (operation == 1) action = abi.encodeCall(IAccessControl.grantRole, (she.MANAGER_ROLE(), bob));
            if (operation == 2) action = abi.encodeCall(IAccessControl.revokeRole, (she.MANAGER_ROLE(), manager));
            receiver.configure(action, 0);
            fault.setCallback(receiver);
            vm.warp(expected.eligibleAt);
            PayoutSnapshot memory p;
            p.count = overseer.burnCount();
            p.heldBefore = token.sharesOf(address(she));
            p.upstreamBefore = address(overseer).balance;
            assertTrue(she.hasRole(she.MANAGER_ROLE(), recipient));
            assertFalse(she.isLocked());
            vm.prank(alice);
            assertEq(she.executeWithdrawal(id, 6 ether), 6 ether);
            assertEq(overseer.burnCount(), p.count);
            assertEq(wrapper.balanceOf(alice), 6 ether);
            assertEq(receiver.callbackCount(), 1, "fault-injected callback did not complete");
            assertTrue(receiver.observedLocked());
            assertEq(receiver.actionSucceeded(), operation == 0);
            assertEq(
                receiver.actionResultHash(),
                keccak256(
                    operation == 0
                        ? bytes("")
                        : abi.encodeWithSelector(
                            IAccessControl.AccessControlUnauthorizedAccount.selector, recipient, bytes32(0)
                        )
                )
            );
            assertTrue(receiver.consumerRejected());
            assertEq(she.hasRole(she.MANAGER_ROLE(), recipient), operation != 0);
            assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
            assertFalse(she.hasRole(she.MANAGER_ROLE(), bob));
            assertEq(she.defaultAdmin(), address(this));
            assertEq(recipient.balance, 0);
            assertEq(address(overseer).balance, p.upstreamBefore);
            assertEq(token.sharesOf(address(she)), p.heldBefore - 6 ether * 1e6);
            assertEq(abi.encode(storedAccounting()), abi.encode(I.Accounting(4 ether * 1e6, 4 ether * 1e6, 0, 0)));
            (uint256 remaining,,) = she.account(alice);
            assertEq(remaining, 4 ether * 1e6 - SEED);
            expected.status = I.RequestStatus.EXECUTED;
            assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(expected));
            assertFalse(she.isLocked());
            assertFalse(she.paused());
            backed();
            assertTrue(vm.revertTo(state));
        }
    }

    function test_callbacksCannotReenterAnyProtectedOperationAndConsumerRejectsReads() public {
        for (uint256 operation; operation < 11; ++operation) {
            // Use an isolated fixture per operation so each attempted call is otherwise authorized and usable.
            uint256 state = vm.snapshot();
            SheCallbackWrapper fault = installCallbackWrapper();
            SheGuardedConsumer consumer = new SheGuardedConsumer(she);
            SheReentrantRecipient recipient = new SheReentrantRecipient(she, consumer);
            address receiver = address(recipient);
            extraActors.push(receiver);
            uint256 receiverUnits = deposit(receiver, 2 ether);
            uint256 innerId = request(receiver, 1 ether * 1e6);
            overseer.mint{value: 1 ether}(receiver);
            vm.prank(receiver);
            wrapper.approve(address(she), 1 ether);
            she.grantRole(she.MANAGER_ROLE(), receiver);
            she.grantRole(she.REWARD_DISTRIBUTOR_ROLE(), receiver);
            if (operation >= 6 && operation <= 8) {
                she.beginDefaultAdminTransfer(receiver);
                (, uint48 schedule) = she.pendingDefaultAdmin();
                vm.warp(uint256(schedule) + 1);
                vm.prank(receiver);
                she.acceptDefaultAdminTransfer();
                assertTrue(she.hasRole(she.DEFAULT_ADMIN_ROLE(), receiver));
                if (operation == 8) {
                    vm.startPrank(receiver);
                    she.revokeRole(she.MANAGER_ROLE(), receiver);
                    vm.stopPrank();
                    assertFalse(she.hasRole(she.MANAGER_ROLE(), receiver));
                }
            }
            uint256 outerId = request(alice, deposit(alice, 10 ether));
            vm.warp(she.getWithdrawalRequest(outerId).eligibleAt);
            bytes memory action;
            if (operation == 0) action = abi.encodeCall(I.deposit, (1 ether, receiver, 0, 0));
            if (operation == 1) {
                action = abi.encodeCall(I.requestWithdrawal, (receiverUnits - 1 ether * 1e6, 0));
            }
            if (operation == 2) action = abi.encodeCall(I.executeWithdrawal, (innerId, 0));
            if (operation == 3) action = abi.encodeCall(I.fundRewards, (0));
            if (operation == 4) action = abi.encodeCall(I.checkpointRewards, ());
            if (operation == 5) action = abi.encodeCall(I.setPaused, (true));
            if (operation == 6) action = abi.encodeCall(I.setCooldown, (5));
            if (operation == 7) action = abi.encodeCall(I.setRewardDuration, (50));
            if (operation == 8) action = abi.encodeCall(I.setPaused, (true));
            if (operation == 9) action = abi.encodeCall(I.cancelWithdrawal, (innerId, 0));
            if (operation == 10) {
                rescueToken = new SheRescueToken(she);
                rescueToken.mint(address(she), 1 ether);
                action = abi.encodeCall(I.rescueTokens, (address(rescueToken), receiver, 1 ether));
            }
            recipient.configure(action, operation == 3 ? 1 : 0);
            fault.setCallback(recipient);
            vm.deal(receiver, 1);
            uint256 activeBefore = consumer.activeAssets();
            bytes memory innerBefore = abi.encode(she.getWithdrawalRequest(innerId));
            uint256 custodyBefore = token.sharesOf(address(she));
            uint256 count = overseer.burnCount();
            // Capture before prank: this external read must not consume the owner impersonation.
            vm.prank(alice);
            assertEq(she.executeWithdrawal(outerId, 10 ether), 10 ether);
            assertEq(overseer.burnCount(), count);
            assertEq(wrapper.balanceOf(alice), 10 ether);
            assertEq(recipient.callbackCount(), 1, "fault-injected callback did not complete");
            assertTrue(recipient.observedLocked());
            assertFalse(recipient.actionSucceeded());
            assertEq(recipient.actionError(), ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
            assertEq(
                recipient.actionResultHash(),
                keccak256(abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector))
            );
            assertTrue(recipient.consumerRejected());
            assertFalse(she.isLocked());
            assertEq(receiver.balance, 1);
            assertEq(wrapper.allowance(receiver, address(she)), 1 ether);
            assertEq(wrapper.balanceOf(receiver), 1 ether);
            assertEq(consumer.activeAssets(), activeBefore);
            assertEq(abi.encode(she.getWithdrawalRequest(innerId)), innerBefore);
            assertEq(token.sharesOf(address(she)), custodyBefore - 10 ether * 1e6);
            assertFalse(she.paused());
            assertEq(abi.encode(she.configuration()), abi.encode(params().configuration));
            assertEq(she.totalAccounting().requestedRawShares, 1 ether * 1e6);
            assertEq(she.totalAccounting().rewardRawShares, 0);
            if (operation == 10) {
                assertEq(rescueToken.balanceOf(address(she)), 1 ether);
                assertEq(rescueToken.balanceOf(receiver), 0);
            }
            assertTrue(vm.revertTo(state));
        }
    }
}
