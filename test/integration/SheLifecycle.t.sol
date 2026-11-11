// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {Overseer} from "../../src/Overseer.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract SheUpgradeCandidate is StakedHypeEscrow {
    uint256 public migrationMarker;

    function initializeV2(uint256 marker) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        migrationMarker = marker;
    }

    function revision() external pure returns (uint256) {
        return 2;
    }
}

contract SheLifecycleTest is SheAssertions {
    uint64 private eventCooldown;

    function test_upgradePreservesCoolingClaimsAndProspectiveDurations() public {
        deposit(alice, 100 ether);
        deposit(bob, 100 ether);
        she.setCooldown(20);
        uint256 matureId = request(alice, 10 ether * 1e6);
        fund(10 ether);
        vm.warp(block.timestamp + 25);
        she.setCooldown(40);
        uint256 coolingId = request(bob, 20 ether * 1e6);
        she.setCooldown(7);
        she.setRewardDuration(200);
        donate(2 ether); // Preserve unabsorbed surplus across the upgrade as well.
        I.WithdrawalRequest memory mature = she.getWithdrawalRequest(matureId);
        I.WithdrawalRequest memory cooling = she.getWithdrawalRequest(coolingId);
        (I.RewardStream memory original,) = she.rewardState();
        assertEq(mature.eligibleAt, mature.requestedAt + 20);
        assertEq(cooling.eligibleAt, cooling.requestedAt + 40);
        assertLt(mature.eligibleAt, block.timestamp);
        assertGt(cooling.eligibleAt, block.timestamp);
        assertEq(original.end, original.start + 100);
        assertGt(original.end, block.timestamp);
        bytes32 beforeState = snapshot();
        ProxyAdmin admin = ProxyAdmin(
            address(uint160(uint256(vm.load(address(she), bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)))))
        );
        SheUpgradeCandidate candidate = new SheUpgradeCandidate();
        vm.prank(upgradeGov);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(she)), address(candidate), "");
        assertEq(snapshot(), beforeState);
        assertEq(SheUpgradeCandidate(address(she)).revision(), 2);
        assertEq(she.configuration().cooldown, 7);
        assertEq(she.configuration().rewardDuration, 200);
        assertEq(abi.encode(she.getWithdrawalRequest(matureId)), abi.encode(mature));
        assertEq(abi.encode(she.getWithdrawalRequest(coolingId)), abi.encode(cooling));
        executeAndAssertPayout(alice, matureId, mature.rawShares / 1e6);
        reject(
            bob,
            0,
            abi.encodeCall(I.executeWithdrawal, (coolingId, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        uint256 freshId = request(alice, 1 ether * 1e6);
        I.WithdrawalRequest memory fresh = she.getWithdrawalRequest(freshId);
        assertEq(freshId, coolingId + 1);
        assertEq(fresh.eligibleAt, block.timestamp + 7);
        executeAndAssertPayout(alice, freshId, fresh.rawShares / 1e6);
        assertLt(block.timestamp, cooling.eligibleAt);
        vm.warp(cooling.eligibleAt - 1);
        reject(
            bob,
            0,
            abi.encodeCall(I.executeWithdrawal, (coolingId, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        assertEq(abi.encode(she.getWithdrawalRequest(coolingId)), abi.encode(cooling));
        vm.warp(cooling.eligibleAt);
        executeAndAssertPayout(bob, coolingId, cooling.rawShares / 1e6);
        (I.RewardStream memory running,) = she.rewardState();
        assertEq(running.start, original.start);
        assertEq(running.end, original.end);
        assertEq(running.totalRawShares, original.totalRawShares);
        vm.warp(original.end - 1);
        reject(
            distributor,
            1 ether,
            abi.encodeCall(I.fundRewards, (0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__StreamActive.selector)
        );
        vm.warp(original.end);
        uint256 active = she.totalAccounting().activeRawShares;
        fund(1 ether);
        (I.RewardStream memory next, uint256 retained) = she.rewardState();
        assertEq(abi.encode(next), abi.encode(I.RewardStream(1 ether * 1e6, 0, original.end, original.end + 200)));
        assertEq(retained, 0);
        assertEq(storedAccounting().activeRawShares, active);
        assertEq(storedAccounting().requestedRawShares, 0);
        assertEq(storedAccounting().rewardRawShares, 1 ether * 1e6);
        backed();
    }

    function test_operationalRolesCannotUpgradeThroughEitherEntryPoint() public {
        deposit(alice, 10 ether);
        request(alice, 2 ether * 1e6);
        fund(1 ether);
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 adminBefore = vm.load(address(she), adminSlot);
        bytes32 implementationBefore = vm.load(address(she), implementationSlot);
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(adminBefore))));
        SheUpgradeCandidate candidate = new SheUpgradeCandidate();
        bytes32 beforeState = snapshot();
        address[4] memory callers = [address(this), manager, distributor, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            vm.prank(callers[i]);
            admin.upgradeAndCall(ITransparentUpgradeableProxy(address(she)), address(candidate), "");
            assertEq(snapshot(), beforeState);
            // Non-admin proxy callers delegate to SHE, which has no upgrade selector or fallback.
            reject(
                callers[i],
                0,
                abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (address(candidate), bytes(""))),
                bytes("")
            );
            assertEq(vm.load(address(she), adminSlot), adminBefore);
            assertEq(vm.load(address(she), implementationSlot), implementationBefore);
            assertEq(admin.owner(), upgradeGov);
        }
        reject(
            upgradeGov,
            0,
            abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (address(candidate), bytes(""))),
            bytes("")
        );
        assertEq(vm.load(address(she), adminSlot), adminBefore);
        assertEq(vm.load(address(she), implementationSlot), implementationBefore);
        assertEq(snapshot(), beforeState);
    }

    function test_wstHypeExitPreservesOtherClaimsAndAllowsOwnerToRedeemSeparately() public {
        deposit(bob, 20 ether);
        uint256 other = request(bob, 3 ether * 1e6);
        uint256 id = request(alice, deposit(alice, 10 ether));
        fund(2 ether);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        setLiquidity(4 ether);
        bytes memory otherBefore = abi.encode(she.getWithdrawalRequest(other));
        executeAndAssertPayout(alice, id, 10 ether);
        assertEq(abi.encode(she.getWithdrawalRequest(other)), otherBefore);
        bytes32 escrowBefore = keccak256(abi.encode(storedAccounting(), she.getWithdrawalRequest(id), rewardSnapshot()));
        uint256 count = overseer.burnCount();
        vm.prank(alice);
        uint256 last = overseer.burnAndRedeemIfPossible(alice, 10 ether, "");
        assertEq(last, count + 1);
        assertBurn(count, 4 ether, alice, true);
        assertBurn(last, 6 ether, alice, false);
        assertEq(alice.balance, 4 ether);
        assertEq(wrapper.balanceOf(alice), 0);
        setLiquidity(6 ether);
        overseer.redeem(last);
        assertEq(alice.balance, 10 ether);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(
            keccak256(abi.encode(storedAccounting(), she.getWithdrawalRequest(id), rewardSnapshot())), escrowBefore
        );
        assertEq(abi.encode(she.getWithdrawalRequest(other)), otherBefore);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
    }

    function test_exitDoesNotDependOnPreSyncSupplyOrPartialLiquidity() public {
        uint256 units = deposit(alice, 10 ether);
        deposit(bob, 1 ether);
        uint256 newSupply = token.totalSupply() * 2;
        vm.deal(address(overseer), newSupply);
        token.syncSupply(newSupply, 0);
        uint256 id = request(alice, units);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        setLiquidity(5 ether);
        assertEq(token.preSyncSupply(), 11.02 ether);
        assertEq(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), 20 ether - 1);
        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertEq(token.preSyncSupply(), 11.02 ether);
    }

    function test_executionPreviewAcrossLifecycle() public {
        assertPreview(123, false, 0);
        uint256 id = request(alice, deposit(alice, 10 ether));
        uint256 maturity = she.getWithdrawalRequest(id).eligibleAt;
        assertPreview(id, false, 10 ether - 1);
        vm.warp(maturity - 1);
        assertPreview(id, false, 10 ether - 1);
        vm.warp(maturity);
        assertPreview(id, true, 10 ether - 1);
        vm.prank(manager);
        she.setPaused(true);
        assertPreview(id, false, 10 ether - 1);
        vm.prank(manager);
        she.setPaused(false);
        setLiquidity(0);
        overseer.pauseRedemptionAndBurns();
        assertPreview(id, true, 10 ether - 1);
        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertPreview(id, false, 0);
    }

    function assertPreview(uint256 id, bool eligible, uint256 amount) internal view {
        (bool actualEligible, uint256 actualAmount) = lens.previewExecution(she, id);
        assertEq(actualEligible, eligible);
        assertEq(actualAmount, amount);
    }

    function test_executionPreviewKeepsWstHypeAmountAfterLoss() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        assertPreview(id, true, 10 ether - 1);
        overseer.setMaxSlashPercentage(0.1e18);
        vm.deal(address(overseer), address(overseer).balance * 9 / 10);
        overseer.rebase();
        assertEq(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), 9 ether - 1);
        assertPreview(id, true, 10 ether - 1);
        executeAndAssertPayout(alice, id, 10 ether - 1);
        assertPreview(id, false, 0);
    }

    function test_requestsReconstructedEntirelyFromEvents() public {
        deployEscrowAndReadConfigurationEvent();
        deposit(alice, 10 ether);
        deposit(bob, 20 ether);
        fund(3 ether);
        vm.warp(block.timestamp + 50);
        I.WithdrawalRequest[] memory reconstructed = new I.WithdrawalRequest[](4);
        address[3] memory owners = [alice, bob, alice];
        uint256[3] memory units = [uint256(4 ether * 1e6), uint256(20 ether * 1e6), uint256(6 ether * 1e6 - SEED)];
        uint256 discovered;
        for (uint256 i; i < 3; ++i) {
            if (i != 0) setCooldownAndReadEvent(i == 1 ? 20 : 1);
            uint256 preview = lens.previewRequestWithdrawal(she, owners[i], units[i]);
            vm.recordLogs();
            vm.prank(owners[i]);
            she.requestWithdrawal(units[i], preview);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 found;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].emitter != address(she) || logs[j].topics[0] != I.WithdrawalRequested.selector) continue;
                uint256 id = uint256(logs[j].topics[1]);
                (uint256 emittedUnits, uint256 raw, uint64 eligibleAt) =
                    abi.decode(logs[j].data, (uint256, uint256, uint64));
                assertEq(id, ++discovered);
                assertEq(emittedUnits, units[i]);
                assertEq(raw, preview);
                reconstructed[id] = I.WithdrawalRequest(
                    address(uint160(uint256(logs[j].topics[2]))),
                    raw,
                    eligibleAt - eventCooldown,
                    eligibleAt,
                    I.RequestStatus.REQUESTED
                );
                assertEq(reconstructed[id].owner, owners[i]);
                assertEq(reconstructed[id].requestedAt, block.timestamp);
                assertEq(eligibleAt, block.timestamp + eventCooldown);
                ++found;
            }
            assertEq(found, 1);
            vm.warp(block.timestamp + 1);
        }
        assertEq(discovered, 3);
        for (uint256 id = 1; id <= discovered; ++id) {
            assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(reconstructed[id]));
            if (block.timestamp < reconstructed[id].eligibleAt) vm.warp(reconstructed[id].eligibleAt);
            uint256 payout = reconstructed[id].rawShares / 1e6;
            vm.recordLogs();
            vm.prank(reconstructed[id].owner);
            she.executeWithdrawal(id, payout);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 found;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].emitter != address(she) || logs[j].topics[0] != I.WithdrawalExecuted.selector) continue;
                assertEq(uint256(logs[j].topics[1]), id);
                uint256 amount = abi.decode(logs[j].data, (uint256));
                assertEq(amount, payout);
                reconstructed[id].status = I.RequestStatus.EXECUTED;
                ++found;
            }
            assertEq(found, 1);
            assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(reconstructed[id]));
        }
    }

    function setCooldownAndReadEvent(uint64 cooldown) private {
        vm.recordLogs();
        she.setCooldown(cooldown);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(she));
        assertEq(logs[0].topics[0], keccak256("CooldownSet(uint64)"));
        eventCooldown = abi.decode(logs[0].data, (uint64));
        assertEq(eventCooldown, cooldown);
    }

    function deployEscrowAndReadConfigurationEvent() private {
        vm.recordLogs();
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (params()))
                )
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(she)
                    || logs[i].topics[0] != keccak256("EscrowConfigured(address,address,address,uint64,uint64)")
            ) continue;
            (address st, address wrapped, address upstream, uint64 cooldown, uint64 duration) =
                abi.decode(logs[i].data, (address, address, address, uint64, uint64));
            assertEq(st, address(token));
            assertEq(wrapped, address(wrapper));
            assertEq(upstream, address(overseer));
            assertEq(cooldown, 10);
            assertEq(duration, 100);
            eventCooldown = cooldown;
            ++found;
        }
        assertEq(found, 1);
    }

    function test_populatedProxyUpgradePreservesStateAndContinuesOperating() public {
        deposit(alice, 100 ether);
        deposit(bob, 100 ether);
        uint256 submitted = request(alice, 10 ether * 1e6);
        vm.warp(she.getWithdrawalRequest(submitted).eligibleAt);
        overseer.pauseRedemption();
        vm.prank(alice);
        she.executeWithdrawal(submitted, 10 ether);
        vm.prank(alice);
        uint256 oldBurn = overseer.burn(alice, 10 ether);
        overseer.unpauseRedemption();
        uint256 pending = request(bob, 20 ether * 1e6);
        fund(10 ether);
        vm.warp(block.timestamp + 25);
        donate(2 ether);
        address successor = address(0xCA501);
        extraActors.push(successor);
        vm.deal(successor, 10 ether);
        she.grantRole(she.MANAGER_ROLE(), successor);
        she.grantRole(she.REWARD_DISTRIBUTOR_ROLE(), successor);
        she.revokeRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor);
        she.beginDefaultAdminTransfer(successor);
        vm.prank(manager);
        she.setPaused(true);
        bytes32 beforeState = snapshot();
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(she), adminSlot)))));
        assertEq(admin.owner(), upgradeGov);
        SheUpgradeCandidate candidate = new SheUpgradeCandidate();
        vm.prank(upgradeGov);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(she)), address(candidate), "");
        assertEq(snapshot(), beforeState);
        assertEq(SheUpgradeCandidate(address(she)).revision(), 2);
        assertEq(
            vm.load(address(she), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)),
            bytes32(uint256(uint160(address(candidate))))
        );
        assertEq(admin.owner(), upgradeGov);
        reject(
            bob,
            0,
            abi.encodeCall(SheUpgradeCandidate.initializeV2, (42)),
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, bytes32(0))
        );
        assertEq(SheUpgradeCandidate(address(she)).migrationMarker(), 0);
        SheUpgradeCandidate(address(she)).initializeV2(42);
        assertEq(SheUpgradeCandidate(address(she)).migrationMarker(), 42);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SheUpgradeCandidate(address(she)).initializeV2(43);
        vm.prank(successor);
        she.setPaused(false);
        overseer.unpauseRedemption();
        overseer.redeem(oldBurn);
        assertEq(alice.balance, 10 ether);
        vm.prank(bob);
        she.executeWithdrawal(pending, 20 ether);
        assertEq(wrapper.balanceOf(bob), 20 ether);
        uint256 newUnits = deposit(alice, 5 ether);
        assertGt(newUnits, 0);
        (I.RewardStream memory stream,) = she.rewardState();
        vm.warp(stream.end);
        vm.prank(successor);
        she.fundRewards{value: 1 ether}(1 ether * 1e6);
        assertTrue(she.hasRole(she.MANAGER_ROLE(), successor));
        assertFalse(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        uint256 fresh = request(alice, newUnits);
        assertEq(fresh, pending + 1);
        vm.warp(she.getWithdrawalRequest(fresh).eligibleAt);
        vm.prank(alice);
        she.executeWithdrawal(fresh, 1);
        assertEq(uint256(she.getWithdrawalRequest(fresh).status), uint256(I.RequestStatus.EXECUTED));
        assertBurn(oldBurn, 10 ether, alice, true);
        assertEq(SheUpgradeCandidate(address(she)).migrationMarker(), 42);
        vm.prank(successor);
        she.acceptDefaultAdminTransfer();
        assertEq(she.defaultAdmin(), successor);
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), address(this)));
    }
}
