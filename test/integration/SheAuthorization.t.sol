// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract SheInvalidDependency {
    address public immutable sthype;
    uint256 public immutable balanceToShareDecimals;

    constructor(address token, uint256 quantum) {
        sthype = token;
        balanceToShareDecimals = quantum;
    }
}

contract SheAuthorizationTest is SheAssertions {
    function test_transferHasNoUint88LimitWithPartialLiquidity() public {
        vm.deal(address(this), 400_000_000e18);
        uint256 units = deposit(alice, 200_000_000e18);
        deposit(bob, 200_000_000e18);
        uint256 id = request(alice, units);
        uint256 newSupply = token.totalSupply() * 2;
        vm.deal(address(overseer), newSupply);
        token.syncSupply(newSupply, 0);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);
        setLiquidity(200_000_000e18);
        assertGt(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), type(uint88).max);
        executeAndAssertPayout(alice, id, 200_000_000e18 - 1);
    }

    function test_transferHasNoUint88LimitAfterAppreciation() public {
        vm.deal(address(this), 400_000_000e18);
        uint256 units = deposit(alice, 200_000_000e18);
        deposit(bob, 200_000_000e18);
        uint256 id = request(alice, units);
        uint256 newSupply = token.totalSupply() * 2;
        vm.deal(address(overseer), newSupply);
        token.syncSupply(newSupply, 0);
        vm.warp(she.getWithdrawalRequest(id).eligibleAt);

        assertGt(token.sharesToBalance(she.getWithdrawalRequest(id).rawShares), type(uint88).max);
        executeAndAssertPayout(alice, id, 200_000_000e18 - 1);
    }

    function roleError(address caller, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }

    function test_unauthorizedAndRevokedOperationalRolesRollBack() public {
        deposit(alice, 10 ether);
        deposit(bob, 20 ether);
        fund(3 ether);
        vm.warp(block.timestamp + 50);
        donate(2 ether);
        vm.deal(alice, 2 ether);
        bytes memory pause = abi.encodeCall(I.setPaused, (true));
        bytes memory funding = abi.encodeCall(I.fundRewards, (0));
        reject(alice, 0, pause, roleError(alice, she.MANAGER_ROLE()));
        reject(alice, 1 ether, funding, roleError(alice, she.REWARD_DISTRIBUTOR_ROLE()));
        reject(distributor, 0, pause, roleError(distributor, she.MANAGER_ROLE()));
        reject(manager, 0, funding, roleError(manager, she.REWARD_DISTRIBUTOR_ROLE()));
        reject(
            alice,
            0,
            abi.encodeCall(IAccessControl.grantRole, (she.MANAGER_ROLE(), alice)),
            roleError(alice, bytes32(0))
        );
        reject(
            alice,
            0,
            abi.encodeCall(IAccessControl.revokeRole, (she.MANAGER_ROLE(), manager)),
            roleError(alice, bytes32(0))
        );
        vm.prank(manager);
        she.setPaused(true);
        she.revokeRole(she.MANAGER_ROLE(), manager);
        she.revokeRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor);
        reject(manager, 0, abi.encodeCall(I.setPaused, (false)), roleError(manager, she.MANAGER_ROLE()));
        reject(distributor, 1 ether, funding, roleError(distributor, she.REWARD_DISTRIBUTOR_ROLE()));
        assertTrue(she.paused());
        she.grantRole(she.MANAGER_ROLE(), bob);
        she.grantRole(she.REWARD_DISTRIBUTOR_ROLE(), alice);
        vm.prank(bob);
        she.setPaused(false);
        assertFalse(she.paused());
        (I.RewardStream memory oldStream,) = she.rewardState();
        vm.warp(oldStream.end);
        vm.prank(alice);
        she.fundRewards{value: 1 ether}(1 ether * 1e6);
        assertFalse(she.hasRole(she.MANAGER_ROLE(), manager));
        assertFalse(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        (I.RewardStream memory next,) = she.rewardState();
        assertEq(next.totalRawShares, 1 ether * 1e6);
    }

    function test_cooldownAndZeroFundingFailuresPreserveFullState() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        deposit(bob, 10 ether);
        fund(2 ether);
        vm.warp(block.timestamp + 9);
        donate(1 ether);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
        );
        reject(
            distributor,
            0,
            abi.encodeCall(I.fundRewards, (0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
        );
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        she.executeWithdrawal(id, 10 ether - 1);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
    }

    function test_initializationRejectsInvalidConfigurationAtomically() public {
        she = StakedHypeEscrow(address(new TransparentUpgradeableProxy(address(implementation), upgradeGov, "")));
        SheInvalidDependency wrongToken = new SheInvalidDependency(address(0xBAD), 1e6);
        SheInvalidDependency wrongQuantum = new SheInvalidDependency(address(token), 1);
        for (uint256 i; i < 12; ++i) {
            I.InitializationParams memory p = params();
            if (i == 0) p.configuration.stHype = address(0);
            if (i == 1) p.configuration.wstHype = address(0);
            if (i == 2) p.configuration.overseer = address(0);
            if (i == 3) p.configuration.cooldown = 0;
            if (i == 4) p.configuration.rewardDuration = 0;
            if (i == 5) p.configuration.rewardDuration = 7 days + 1;
            if (i == 6) p.defaultAdmin = address(0);
            if (i == 7) p.manager = address(0);
            if (i == 8) p.rewardDistributor = address(0);
            if (i == 9) p.configuration.wstHype = address(wrongToken);
            if (i == 10) p.configuration.wstHype = address(wrongQuantum);
            if (i == 11) p.configuration.overseer = address(wrongToken);
            reject(
                address(this),
                0,
                abi.encodeCall(I.initialize, (p)),
                abi.encodeWithSelector(I.StakedHypeEscrow__InvalidConfiguration.selector)
            );
            assertEq(she.defaultAdmin(), address(0));
            assertFalse(she.hasRole(she.MANAGER_ROLE(), manager));
        }
        vm.expectEmit(address(she));
        emit I.EscrowConfigured(address(token), address(wrapper), address(overseer), 10, 100);
        she.initialize(params());
        assertEq(abi.encode(she.configuration()), abi.encode(params().configuration));
        assertEq(she.defaultAdmin(), address(this));
        assertTrue(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        assertEq(deposit(alice, 1 ether), 1 ether * 1e6 - SEED);
    }

    function test_cooldownRejectsZeroAndValuesAboveOneHundredEightyDays() public {
        she = StakedHypeEscrow(address(new TransparentUpgradeableProxy(address(implementation), upgradeGov, "")));
        uint64[3] memory durations = [uint64(0), uint64(180 days + 1), type(uint64).max];
        for (uint256 i; i < durations.length; ++i) {
            I.InitializationParams memory p = params();
            p.configuration.cooldown = durations[i];
            reject(
                address(this),
                0,
                abi.encodeCall(I.initialize, (p)),
                abi.encodeWithSelector(I.StakedHypeEscrow__InvalidConfiguration.selector)
            );
        }
        // Every rejected initialization leaves the same proxy usable with a valid configuration.
        she.initialize(params());
        assertEq(she.configuration().cooldown, 10);
        assertEq(deposit(alice, 1 ether), 1 ether * 1e6 - SEED);
    }

    function test_cooldownAcceptsOneSecondAndOneHundredEightyDays() public {
        uint64[2] memory durations = [uint64(1), uint64(180 days)];
        for (uint256 i; i < durations.length; ++i) {
            I.InitializationParams memory p = params();
            p.configuration.cooldown = durations[i];
            she = StakedHypeEscrow(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (p))
                    )
                )
            );
            assertEq(she.configuration().cooldown, durations[i]);
            uint256 created = block.timestamp;
            uint256 id = request(alice, deposit(alice, 1 ether));
            I.WithdrawalRequest memory withdrawal = she.getWithdrawalRequest(id);
            assertEq(withdrawal.requestedAt, created);
            assertEq(withdrawal.eligibleAt, created + durations[i]);
            vm.warp(withdrawal.eligibleAt - 1);
            (bool eligible,) = lens.previewExecution(she, id);
            assertFalse(eligible);
            reject(
                alice,
                0,
                abi.encodeCall(I.executeWithdrawal, (id, 1 ether)),
                abi.encodeWithSelector(I.StakedHypeEscrow__CooldownNotElapsed.selector)
            );
            vm.warp(withdrawal.eligibleAt);
            (eligible,) = lens.previewExecution(she, id);
            assertTrue(eligible);
            executeAndAssertPayout(alice, id, 1 ether - 1);
        }
    }

    function test_invalidInputsAndBothDepositMinimaPreserveFullState() public {
        uint256 units = deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        fund(2 ether);
        vm.warp(block.timestamp + 50);
        donate(1 ether);
        overseer.mint{value: 1 ether}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 1 ether);
        bytes memory invalidAddress = abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAddress.selector);
        bytes memory invalidAmount = abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector);
        bytes memory minimum = abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector);
        reject(bob, 0, abi.encodeCall(I.deposit, (1 ether, address(0), 0, 0)), invalidAddress);
        reject(bob, 0, abi.encodeCall(I.deposit, (1 ether, address(she), 0, 0)), invalidAddress);
        reject(bob, 0, abi.encodeCall(I.deposit, (0, bob, 0, 0)), invalidAmount);
        // Independent pre-entry rate: 20 principal + 1 elapsed reward + 1 donation, with 20 units.
        uint256 issued = uint256(1 ether * 1e6) * (20 ether * 1e6) / (22 ether * 1e6);
        reject(bob, 0, abi.encodeCall(I.deposit, (1 ether, bob, issued + 1, 0)), minimum);
        reject(bob, 0, abi.encodeCall(I.deposit, (1 ether, bob, 0, 1 ether + 1)), minimum);
        reject(alice, 0, abi.encodeCall(I.requestWithdrawal, (0, 0)), invalidAmount);
        reject(
            alice,
            0,
            abi.encodeCall(I.requestWithdrawal, (units + 1, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InsufficientUnits.selector)
        );
        reject(alice, 0, abi.encodeCall(I.requestWithdrawal, (units, 11 ether * 1e6 + 1)), minimum);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (1, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidRequest.selector)
        );
        token.pauseTransfer(true);
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)),
            abi.encodeWithSelector(stHYPE.TransferIsPaused.selector)
        );
        token.pauseTransfer(false);
        vm.expectEmit(address(she));
        emitExpectedDeposited(bob, bob, 1 ether, issued);
        vm.prank(bob);
        (uint256 actual, uint256 accepted) = she.deposit(1 ether, bob, issued, 1 ether);
        assertEq(actual, issued);
        assertEq(accepted, 1 ether);
        assertEq(wrapper.allowance(bob, address(she)), 0);
    }

    function test_fundingAndExecutionFailuresRestoreCheckpointAndProtocolState() public {
        uint256 id = request(alice, deposit(alice, 10 ether));
        deposit(bob, 10 ether);
        fund(2 ether);
        vm.warp(block.timestamp + 50);
        donate(1 ether);
        reject(
            distributor,
            1 ether,
            abi.encodeCall(I.fundRewards, (0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__StreamActive.selector)
        );
        reject(
            bob,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 10 ether + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 10 ether + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        vm.warp(block.timestamp + 50);
        reject(
            distributor,
            1 ether,
            abi.encodeCall(I.fundRewards, (1 ether * 1e6 + 1)),
            abi.encodeWithSelector(I.StakedHypeEscrow__MinimumNotMet.selector)
        );
        vm.expectEmit(address(she));
        emitExpectedRewardsFunded(
            1 ether, 1 ether * 1e6, 1 ether * 1e6, uint64(block.timestamp), uint64(block.timestamp + 100)
        );
        fund(1 ether);
        vm.prank(manager);
        she.setPaused(true);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__Paused.selector)
        );
        vm.expectEmit(address(she));
        emit I.PausedSet(false);
        vm.prank(manager);
        she.setPaused(false);
        vm.prank(alice);
        she.executeWithdrawal(id, 10 ether - 1);
        assertEq(wrapper.balanceOf(alice), 10 ether - 1);
    }
}
