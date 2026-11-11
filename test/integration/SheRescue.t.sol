// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Vm} from "forge-std/Vm.sol";

contract SheRescueToken is ERC20 {
    error TransferRejected();

    I private immutable escrow;
    uint256 public mode;
    bytes private action;
    bool private bubbleCallback;
    bool public observedLocked;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor(I escrow_) ERC20("Rescue fixture", "RESCUE") {
        escrow = escrow_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 mode_, bytes calldata action_, bool bubbleCallback_) external {
        mode = mode_;
        action = action_;
        bubbleCallback = bubbleCallback_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Mutate before failing so tests verify rollback of the rescued token as well as SHE.
        super.transfer(to, amount);
        if (action.length != 0) {
            observedLocked = escrow.isLocked();
            (bool success, bytes memory result) = address(escrow).call(action);
            callbackSucceeded = success;
            callbackResult = result;
            if (!success && bubbleCallback) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }
        if (mode == 1) return false;
        if (mode == 2) revert TransferRejected();
        if (mode == 3) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}

contract SheRescueTest is SheAssertions {
    SheRescueToken private coin;
    address private recipient = address(0xbeef);

    function setUp() public override {
        super.setUp();
        coin = new SheRescueToken(she);
        extraActors.push(recipient);
        extraActors.push(address(coin));
        deposit(alice, 10 ether);
        deposit(bob, 6 ether);
        request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 5);
        donate(1 ether); // Leave both elapsed rewards and unrecognized surplus uncheckpointed.
        vm.deal(address(she), 3 ether); // Native HYPE may be force-sent even without a receive function.
        coin.mint(address(she), 100 ether);
        coin.mint(recipient, 7 ether);
    }

    function test_adminAndManagerRescuePartialAndFullBalancesWhilePausedOrUnpaused() public {
        for (uint256 i; i < 4; ++i) {
            uint256 branch = vm.snapshot();
            she.setPaused(i >= 2);
            address caller = i % 2 == 0 ? address(this) : manager;
            rescueAndAssert(caller, 30 ether);
            rescueAndAssert(caller, 70 ether);
            assertEq(coin.balanceOf(address(she)), 0);
            assertEq(coin.balanceOf(recipient), 107 ether);
            assertTrue(vm.revertTo(branch));
        }
    }

    function testFuzz_rescuePreservesAllEscrowState(uint96 amountSeed, bool asManager, bool isPaused) public {
        uint256 amount = bound(uint256(amountSeed), 1, 100 ether);
        she.setPaused(isPaused);
        rescueAndAssert(asManager ? manager : address(this), amount);
    }

    function test_rescueIgnoresEveryUpstreamOutageForBothRolesAndPauseStates() public {
        for (uint256 mask = 1; mask < 8; ++mask) {
            for (uint256 i; i < 4; ++i) {
                uint256 branch = vm.snapshot();
                she.setPaused(i >= 2);
                address caller = i % 2 == 0 ? address(this) : manager;
                rescueAndAssert(caller, 30 ether, mask);
                rescueAndAssert(caller, 70 ether, mask);
                assertEq(coin.balanceOf(address(she)), 0);
                assertEq(coin.balanceOf(recipient), 107 ether);
                assertTrue(vm.revertTo(branch));
            }
        }
    }

    function test_failedRescueDuringUpstreamOutageRollsBackAndAllowsRetry() public {
        she.setPaused(true);
        for (uint256 mode = 1; mode <= 2; ++mode) {
            coin.configure(mode, "", false);
            bytes32 beforeState = snapshot();
            bytes32 beforeTokens = coinSnapshot();
            mockUpstreamOutage(7);
            vm.prank(manager);
            (bool success, bytes memory result) =
                address(she).call(abi.encodeCall(I.rescueTokens, (address(coin), recipient, 1 ether)));
            vm.clearMockedCalls();
            assertFalse(success);
            assertEq(
                result,
                mode == 1
                    ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(coin))
                    : abi.encodeWithSelector(SheRescueToken.TransferRejected.selector)
            );
            assertEq(snapshot(), beforeState);
            assertEq(coinSnapshot(), beforeTokens);
            assertFalse(she.isLocked());
        }
        coin.configure(0, "", false);
        rescueAndAssert(manager, 100 ether, 7);
    }

    function test_unauthorizedAndRevokedRolesCannotRescue() public {
        address[4] memory callers = [alice, bob, distributor, upgradeGov];
        for (uint256 i; i < callers.length; ++i) {
            rejectRescue(
                callers[i],
                address(coin),
                recipient,
                1,
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], she.MANAGER_ROLE()
                )
            );
        }
        she.revokeRole(she.MANAGER_ROLE(), manager);
        rejectRescue(
            manager,
            address(coin),
            recipient,
            1,
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, manager, she.MANAGER_ROLE()
            )
        );
        she.grantRole(she.MANAGER_ROLE(), bob);
        rescueAndAssert(bob, 1 ether);
    }

    function test_defaultAdminTransferUpdatesRescueAuthority() public {
        she.beginDefaultAdminTransfer(bob);
        (, uint48 schedule) = she.pendingDefaultAdmin();
        vm.warp(uint256(schedule) + 1);
        vm.prank(bob);
        she.acceptDefaultAdminTransfer();
        rejectRescue(
            address(this),
            address(coin),
            recipient,
            1,
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), she.MANAGER_ROLE()
            )
        );
        rescueAndAssert(bob, 1 ether);
        rescueAndAssert(manager, 1 ether);
    }

    function test_protectedAssetsCannotBeRescuedByEitherRoleInEitherPauseState() public {
        address[3] memory protectedTokens = [address(0), address(token), address(wrapper)];
        for (uint256 i; i < 4; ++i) {
            she.setPaused(i >= 2);
            for (uint256 j; j < protectedTokens.length; ++j) {
                // Prove rejection occurs before calling the protected token, even for surplus shares.
                vm.mockCallRevert(
                    protectedTokens[j], abi.encodeWithSelector(ERC20.transfer.selector), bytes("must not call token")
                );
                rejectRescue(
                    i % 2 == 0 ? address(this) : manager,
                    protectedTokens[j],
                    recipient,
                    1 ether,
                    abi.encodeWithSelector(I.StakedHypeEscrow__ProtectedToken.selector)
                );
                vm.clearMockedCalls();
            }
        }
        assertEq(address(she).balance, 3 ether);
    }

    function test_invalidRecipientsZeroAmountAndNativeValueAreRejected() public {
        rejectRescue(
            manager, address(coin), address(0), 1, abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAddress.selector)
        );
        rejectRescue(
            manager, address(coin), address(she), 1, abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAddress.selector)
        );
        rejectRescue(
            manager, address(coin), recipient, 0, abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
        );
        bytes32 beforeTokens = coinSnapshot();
        reject(address(this), 1, abi.encodeCall(I.rescueTokens, (address(coin), recipient, 1)), bytes(""));
        assertEq(coinSnapshot(), beforeTokens);
    }

    function test_falseReturnRevertInsufficientBalanceAndNonContractsRollBack() public {
        coin.configure(1, "", false);
        rejectRescue(
            manager,
            address(coin),
            recipient,
            1 ether,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(coin))
        );
        coin.configure(2, "", false);
        rejectRescue(
            manager, address(coin), recipient, 1 ether, abi.encodeWithSelector(SheRescueToken.TransferRejected.selector)
        );
        coin.configure(0, "", false);
        rejectRescue(
            manager,
            address(coin),
            recipient,
            101 ether,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(she), 100 ether, 101 ether)
        );
        address[2] memory nonContracts = [alice, address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)];
        for (uint256 i; i < nonContracts.length; ++i) {
            rejectRescue(
                manager,
                nonContracts[i],
                recipient,
                1,
                abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, nonContracts[i])
            );
        }
        rescueAndAssert(manager, 1 ether); // A failed rescue never leaves the guard locked.
    }

    function test_nonReturningTokenCanBeRescued() public {
        coin.configure(3, "", false);
        rescueAndAssert(manager, 10 ether);
    }

    function test_tokenCallbackCannotReenterRescueOrAccountingOperations() public {
        she.grantRole(she.MANAGER_ROLE(), address(coin));
        vm.warp(she.getWithdrawalRequest(1).eligibleAt);
        for (uint256 i; i < 4; ++i) {
            bytes memory action;
            if (i == 0) action = abi.encodeCall(I.rescueTokens, (address(coin), recipient, 1));
            if (i == 1) action = abi.encodeCall(I.checkpointRewards, ());
            if (i == 2) action = abi.encodeCall(I.setPaused, (true));
            if (i == 3) action = abi.encodeCall(I.executeWithdrawal, (1, 0));
            coin.configure(0, action, false);
            rescueAndAssert(manager, 1 ether);
            assertTrue(coin.observedLocked());
            assertFalse(coin.callbackSucceeded());
            assertEq(
                coin.callbackResult(),
                abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
            );
        }
        coin.configure(0, abi.encodeCall(I.checkpointRewards, ()), true);
        rejectRescue(
            manager,
            address(coin),
            recipient,
            1 ether,
            abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
    }

    function rescueAndAssert(address caller, uint256 amount) private {
        rescueAndAssert(caller, amount, 0);
    }

    function rescueAndAssert(address caller, uint256 amount, uint256 outageMask) private {
        bytes32 beforeState = snapshot();
        uint256 held = coin.balanceOf(address(she));
        uint256 received = coin.balanceOf(recipient);
        uint256 callerBalance = coin.balanceOf(caller);
        uint256 supply = coin.totalSupply();
        // Install only after snapshotting; remove before inspecting protected assets again.
        mockUpstreamOutage(outageMask);
        vm.recordLogs();
        vm.prank(caller);
        she.rescueTokens(address(coin), recipient, amount);
        vm.clearMockedCalls();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 emitted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(she)) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], I.TokensRescued.selector);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(coin)))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(recipient))));
            assertEq(logs[i].data, abi.encode(amount));
            ++emitted;
        }
        assertEq(emitted, 1, "rescue must emit exactly one SHE event without checkpointing");
        assertEq(snapshot(), beforeState, "rescue changed escrow state or protected assets");
        assertEq(coin.balanceOf(address(she)), held - amount);
        assertEq(coin.balanceOf(recipient), received + amount);
        assertEq(coin.balanceOf(caller), callerBalance);
        assertEq(coin.totalSupply(), supply);
        assertEq(coin.allowance(address(she), caller), 0);
        assertEq(coin.allowance(address(she), recipient), 0);
        assertFalse(she.isLocked());
    }

    function mockUpstreamOutage(uint256 mask) private {
        // Empty calldata matches every selector, including unexpected new dependency reads.
        if (mask & 1 != 0) vm.mockCallRevert(address(token), bytes(""), bytes("token unavailable"));
        if (mask & 2 != 0) vm.mockCallRevert(address(wrapper), bytes(""), bytes("wrapper unavailable"));
        if (mask & 4 != 0) vm.mockCallRevert(address(overseer), bytes(""), bytes("overseer unavailable"));
    }

    function rejectRescue(address caller, address asset, address to, uint256 amount, bytes memory reason) private {
        bytes32 beforeTokens = coinSnapshot();
        reject(caller, 0, abi.encodeCall(I.rescueTokens, (asset, to, amount)), reason);
        assertEq(coinSnapshot(), beforeTokens, "failed rescue changed token state");
        assertFalse(she.isLocked());
    }

    function coinSnapshot() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                coin.balanceOf(address(she)),
                coin.balanceOf(recipient),
                coin.totalSupply(),
                coin.allowance(address(she), recipient),
                coin.observedLocked(),
                coin.callbackSucceeded(),
                coin.callbackResult()
            )
        );
    }
}
