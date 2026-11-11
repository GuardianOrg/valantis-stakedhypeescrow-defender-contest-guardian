// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract SheTimelockUpgradeCandidate is StakedHypeEscrow {
    function revision() external pure returns (uint256) {
        return 2;
    }
}

// All authorities and the delay below are local examples, not production configuration.
contract SheTimelockTest is SheAssertions {
    uint256 private constant UPGRADE_DELAY = 2 days;
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address private proposer = address(0x2001);
    address private executor = address(0x2002);
    TimelockController private timelock;
    ProxyAdmin private proxyAdmin;
    SheTimelockUpgradeCandidate private candidate;
    bytes private upgradeData;
    bytes32 private operation;

    function setUp() public override {
        super.setUp();
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(UPGRADE_DELAY, proposers, executors, address(0));
        upgradeGov = address(timelock);
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (params()))
                )
            )
        );
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(she), ADMIN_SLOT)))));
        candidate = new SheTimelockUpgradeCandidate();
        upgradeData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(she)), address(candidate), bytes(""))
        );
        operation = timelock.hashOperation(address(proxyAdmin), 0, upgradeData, bytes32(0), bytes32(0));
        extraActors.push(proposer);
        extraActors.push(executor);
    }

    function test_atomicInitializationAndDistinctAuthorities() public {
        assertEq(proxyAdmin.owner(), address(timelock));
        assertEq(she.defaultAdmin(), address(this));
        assertEq(she.defaultAdminDelay(), 20);
        assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
        assertTrue(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        assertEq(abi.encode(she.configuration()), abi.encode(params().configuration));
        assertEq(timelock.getMinDelay(), UPGRADE_DELAY);
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), address(timelock)));
        reject(
            alice,
            0,
            abi.encodeCall(StakedHypeEscrow.initialize, (params())),
            abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );

        bytes32 beforeState = snapshot();
        address[5] memory callers = [address(this), manager, distributor, proposer, executor];
        for (uint256 i; i < callers.length; ++i) {
            assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), callers[i]));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vm.prank(callers[i]);
            proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(she)), address(candidate), "");
            assertEq(snapshot(), beforeState);
            assertImplementation(address(implementation));
        }
    }

    function test_scheduleAndExecutionEnforceRolesAndInclusiveDelay() public {
        bytes32 beforeState = snapshot();
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        address[3] memory callers = [address(this), manager, distributor];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], proposerRole
                )
            );
            vm.prank(callers[i]);
            timelock.schedule(address(proxyAdmin), 0, upgradeData, 0, 0, UPGRADE_DELAY);
            assertEq(timelock.getTimestamp(operation), 0);
            assertEq(snapshot(), beforeState);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockInsufficientDelay.selector, UPGRADE_DELAY - 1, UPGRADE_DELAY
            )
        );
        vm.prank(proposer);
        timelock.schedule(address(proxyAdmin), 0, upgradeData, 0, 0, UPGRADE_DELAY - 1);
        assertEq(timelock.getTimestamp(operation), 0);
        assertEq(snapshot(), beforeState);

        scheduleUpgrade();
        uint256 readyAt = timelock.getTimestamp(operation);
        vm.warp(readyAt - 1);
        assertExecuteRejected(
            executor,
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operation, bytes32(uint256(4))
            )
        );
        assertEq(timelock.getTimestamp(operation), readyAt);
        vm.warp(readyAt);
        assertTrue(timelock.isOperationReady(operation));
        assertExecuteRejected(
            proposer,
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, proposer, timelock.EXECUTOR_ROLE()
            )
        );
        beforeState = snapshot();
        executeUpgrade();
        assertEq(snapshot(), beforeState);
        assertImplementation(address(candidate));
        assertTrue(timelock.isOperationDone(operation));
        assertEq(SheTimelockUpgradeCandidate(address(she)).revision(), 2);
        assertExecuteRejected(
            executor,
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operation, bytes32(uint256(4))
            )
        );
        assertTrue(timelock.isOperationDone(operation));
    }

    function test_cancelledUpgradeMustWaitForFreshDelay() public {
        scheduleUpgrade();
        uint256 firstReadyAt = timelock.getTimestamp(operation);
        bytes32 beforeState = snapshot();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, executor, cancellerRole)
        );
        vm.prank(executor);
        timelock.cancel(operation);
        assertEq(timelock.getTimestamp(operation), firstReadyAt);
        assertEq(snapshot(), beforeState);
        vm.prank(proposer);
        timelock.cancel(operation);
        assertEq(timelock.getTimestamp(operation), 0);
        assertEq(snapshot(), beforeState);
        vm.warp(firstReadyAt);
        assertExecuteRejected(
            executor,
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operation, bytes32(uint256(4))
            )
        );
        scheduleUpgrade();
        assertEq(timelock.getTimestamp(operation), firstReadyAt + UPGRADE_DELAY);
        assertExecuteRejected(
            executor,
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operation, bytes32(uint256(4))
            )
        );
        vm.warp(firstReadyAt + UPGRADE_DELAY);
        beforeState = snapshot();
        executeUpgrade();
        assertEq(snapshot(), beforeState);
        assertImplementation(address(candidate));
        assertTrue(timelock.isOperationDone(operation));
    }

    function test_timelockedUpgradePreservesPopulatedEscrowAndPayouts() public {
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        uint256 matureId = request(alice, 1 ether * 1e6);
        she.setCooldown(180 days);
        uint256 coolingId = request(bob, 2 ether * 1e6);
        she.setRewardDuration(7 days);
        fund(2 ether);
        donate(1 ether);
        scheduleUpgrade();
        vm.warp(timelock.getTimestamp(operation));
        assertLt(she.getWithdrawalRequest(matureId).eligibleAt, block.timestamp);
        assertGt(she.getWithdrawalRequest(coolingId).eligibleAt, block.timestamp);
        (I.RewardStream memory stream,) = she.rewardState();
        assertGt(stream.end, block.timestamp);
        bytes32 beforeState = snapshot();
        bytes32 rewardsBefore = rewardSnapshot();
        bytes memory accountingBefore = abi.encode(she.totalAccounting());
        executeUpgrade();
        assertEq(snapshot(), beforeState);
        assertEq(rewardSnapshot(), rewardsBefore);
        assertEq(abi.encode(she.totalAccounting()), accountingBefore);
        assertImplementation(address(candidate));
        assertTrue(timelock.isOperationDone(operation));
        executeAndAssertPayout(alice, matureId, 1 ether);
        executeAndAssertPayout(bob, coolingId, 2 ether);
    }

    function scheduleUpgrade() private {
        uint256 readyAt = block.timestamp + UPGRADE_DELAY;
        vm.prank(proposer);
        timelock.schedule(address(proxyAdmin), 0, upgradeData, 0, 0, UPGRADE_DELAY);
        assertEq(timelock.getTimestamp(operation), readyAt);
        assertTrue(timelock.isOperationPending(operation));
        assertImplementation(address(implementation));
    }

    function executeUpgrade() private {
        vm.prank(executor);
        timelock.execute(address(proxyAdmin), 0, upgradeData, 0, 0);
    }

    function assertExecuteRejected(address caller, bytes memory reason) private {
        bytes32 beforeState = snapshot();
        bytes32 beforeImplementation = vm.load(address(she), IMPLEMENTATION_SLOT);
        uint256 beforeTimestamp = timelock.getTimestamp(operation);
        vm.expectRevert(reason);
        vm.prank(caller);
        timelock.execute(address(proxyAdmin), 0, upgradeData, 0, 0);
        assertEq(snapshot(), beforeState);
        assertEq(vm.load(address(she), IMPLEMENTATION_SLOT), beforeImplementation);
        assertEq(timelock.getTimestamp(operation), beforeTimestamp);
        assertEq(proxyAdmin.owner(), address(timelock));
    }

    function assertImplementation(address expected) private view {
        assertEq(address(uint160(uint256(vm.load(address(she), IMPLEMENTATION_SLOT)))), expected);
        assertEq(address(uint160(uint256(vm.load(address(she), ADMIN_SLOT)))), address(proxyAdmin));
        assertEq(proxyAdmin.owner(), address(timelock));
    }
}
