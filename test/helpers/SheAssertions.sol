// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheTestBase} from "./SheTestBase.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";

// An EVM custody fixture: no claims about HyperCore settlement or validator liquidity.
contract SheLiquidityModule {
    address public immutable manager;

    constructor(address manager_) {
        manager = manager_;
    }

    function getTotalBalance() external view returns (uint256) {
        return address(this).balance;
    }
    receive() external payable {}
}

abstract contract SheAssertions is SheTestBase {
    uint256 internal constant SHE_SLOT = 0xecd281f243c16ba7bca6e716285da9e177b38743a79560d95e19c9cd2cf92a00;
    address[] internal extraActors;
    SheLiquidityModule internal liquidityModule;

    function storedAccounting() internal view returns (I.Accounting memory a) {
        a = I.Accounting(
            uint256(vm.load(address(she), bytes32(SHE_SLOT + 4))),
            uint256(vm.load(address(she), bytes32(SHE_SLOT + 5))),
            uint256(vm.load(address(she), bytes32(SHE_SLOT + 6))),
            uint256(vm.load(address(she), bytes32(SHE_SLOT + 7)))
        );
    }

    function rewardSnapshot() internal view returns (bytes32) {
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        return keccak256(abi.encode(stream, retained));
    }

    function snapshot() internal view returns (bytes32 digest) {
        return snapshotFromSlot(0, false);
    }

    function snapshotWithoutConfiguration() internal view returns (bytes32 digest) {
        return snapshotFromSlot(4, false);
    }

    function snapshotWithoutPause() internal view returns (bytes32 digest) {
        return snapshotFromSlot(0, true);
    }

    function snapshotFromSlot(uint256 firstSlot, bool skipPause) private view returns (bytes32 digest) {
        // Includes unprocessed stream/accounting storage, not just surplus-absorbing views.
        for (uint256 i = firstSlot; i < 15; ++i) {
            // The standalone pause flag follows RewardStream, whose packed timestamps occupy slot 10.
            if (skipPause && i == 11) continue;
            digest = keccak256(abi.encode(digest, vm.load(address(she), bytes32(SHE_SLOT + i))));
        }
        uint256 count = uint256(vm.load(address(she), bytes32(SHE_SLOT + 12)));
        for (uint256 id = 1; id <= count + 1; ++id) {
            uint256 slot = uint256(keccak256(abi.encode(id, SHE_SLOT + 14)));
            // Each request occupies owner, rawShares, and packed timestamps/status slots.
            for (uint256 j; j < 3; ++j) {
                digest = keccak256(abi.encode(digest, vm.load(address(she), bytes32(slot + j))));
            }
            digest = keccak256(abi.encode(digest, she.getWithdrawalRequest(id)));
        }
        address[9] memory actors =
            [address(this), alice, bob, manager, distributor, upgradeGov, address(she), address(overseer), address(1)];
        for (uint256 i; i < actors.length; ++i) {
            digest = snapshotActor(digest, actors[i]);
        }
        for (uint256 i; i < extraActors.length; ++i) {
            digest = snapshotActor(digest, extraActors[i]);
        }
        (address nextAdmin, uint48 adminSchedule) = she.pendingDefaultAdmin();
        (uint48 nextDelay, uint48 delaySchedule) = she.pendingDefaultAdminDelay();
        digest = keccak256(
            abi.encode(
                digest,
                she.defaultAdmin(),
                she.defaultAdminDelay(),
                nextAdmin,
                adminSchedule,
                nextDelay,
                delaySchedule,
                she.isLocked()
            )
        );
        digest = keccak256(
            abi.encode(
                digest,
                token.totalShares(),
                token.totalSupply(),
                token.preSyncSupply(),
                token.rewardsToSync(),
                token.syncStart(),
                token.syncEnd()
            )
        );
        digest = keccak256(
            abi.encode(
                digest,
                overseer.getAllBurns(),
                overseer.redeemed(),
                overseer.getNormalizedRedeemedHype(),
                overseer.getLatestCumulativeSlashFactor(),
                overseer.protocolPendingFee(),
                overseer.getTotalBalance()
            )
        );
        for (uint256 id; id < overseer.burnCount(); ++id) {
            digest = keccak256(
                abi.encode(digest, overseer.getCumulativeNormalizedBurns(id), overseer.getCumulativeSlashFactor(id))
            );
        }
    }

    function snapshotActor(bytes32 digest, address actor) private view returns (bytes32) {
        bytes32 units = vm.load(address(she), keccak256(abi.encode(actor, SHE_SLOT + 13)));
        return keccak256(
            abi.encode(
                digest,
                actor,
                actor.balance,
                token.sharesOf(actor),
                wrapper.balanceOf(actor),
                wrapper.allowance(actor, address(she)),
                units,
                she.hasRole(she.DEFAULT_ADMIN_ROLE(), actor),
                she.hasRole(she.MANAGER_ROLE(), actor),
                she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), actor)
            )
        );
    }

    function reject(address caller, uint256 value, bytes memory input, bytes memory expected) internal {
        bytes32 beforeState = snapshot();
        vm.prank(caller);
        (bool success, bytes memory result) = address(she).call{value: value}(input);
        assertFalse(success);
        assertEq(result, expected);
        assertEq(snapshot(), beforeState, "failure changed persistent state");
    }

    function setLiquidity(uint256 amount) internal {
        if (address(liquidityModule) == address(0)) {
            CoreSimulatorLib.init();
            uint256 timestamp = block.timestamp;
            CoreSimulatorLib.setOfflineMode(true);
            // The simulator sets wall-clock time. Liquidity setup must not silently mature requests or finish streams.
            vm.warp(timestamp);
            liquidityModule = new SheLiquidityModule(address(overseer));
            CoreSimulatorLib.forceAccountActivation(address(liquidityModule));
            overseer.addStakingModule(address(liquidityModule));
            extraActors.push(address(liquidityModule));
        }
        uint256 backing = overseer.getTotalBalance();
        assertLe(amount, backing);
        vm.deal(address(overseer), amount);
        vm.deal(address(liquidityModule), backing - amount);
        assertEq(overseer.getTotalBalance(), backing);
        assertFalse(overseer.pendingSlashExists());
    }

    function assertBurn(uint256 id, uint256 amount, address recipient, bool complete) internal view {
        (uint88 actual, address user, bool completed,) = overseer.burns(id);
        assertEq(actual, amount);
        assertEq(user, recipient);
        assertEq(completed, complete);
    }
}
