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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("recipient bookkeeping rejected");
    }
}

contract LockObservingRecipient {
    I immutable escrow;
    uint256 public callbackCount;
    bool public observedLocked;

    constructor(I s) {
        escrow = s;
    }

    receive() external payable {
        callbackCount++;
        observedLocked = escrow.isLocked();
    }
}

abstract contract SheTestBase is Test {
    uint256 internal constant SEED = 1000;
    stHYPE token;
    wstHYPE wrapper;
    Overseer overseer;
    StakedHypeEscrow she;
    StakedHypeEscrow implementation;
    StakedHypeEscrowLens lens;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address manager = address(0x1001);
    address distributor = address(0x1002);
    address upgradeGov = address(0x1003);

    function params() internal view returns (I.InitializationParams memory p) {
        p = I.InitializationParams(
            I.Configuration(address(token), address(wrapper), address(overseer), 10, 100),
            address(this),
            manager,
            distributor,
            20
        );
    }

    function setUp() public virtual {
        vm.warp(1000);
        vm.roll(100);
        vm.deal(address(this), 10000 ether);
        vm.deal(distributor, 10000 ether);
        token = stHYPE(address(new TransparentUpgradeableProxy(address(new stHYPE()), address(this), "")));
        wrapper = wstHYPE(address(new TransparentUpgradeableProxy(address(new wstHYPE()), address(this), "")));
        overseer =
            Overseer(payable(address(new TransparentUpgradeableProxy(address(new Overseer()), address(this), ""))));
        token.initialize(address(this), address(overseer), address(wrapper));
        wrapper.initialize("Staked HYPE Shares", "wstHYPE", 18, address(this), address(token));
        overseer.initialize(address(this), address(token), address(0), address(0));
        overseer.initializeV3();
        overseer.mint{value: 0.02 ether}(address(1)); // preserve real protocol's separate reserve assumption
        implementation = new StakedHypeEscrow();
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (params()))
                )
            )
        );
        lens = new StakedHypeEscrowLens();
    }

    function deposit(address who, uint256 amount) internal returns (uint256 u) {
        overseer.mint{value: amount}(who);
        vm.startPrank(who);
        wrapper.approve(address(she), amount);
        (u,) = she.deposit(amount, who, 1, amount);
        vm.stopPrank();
    }

    function request(address who, uint256 u) internal returns (uint256 id) {
        vm.prank(who);
        id = she.requestWithdrawal(u, 1);
        assertEq(she.getWithdrawalRequest(id).owner, who);
    }

    function fund(uint256 amount) internal {
        vm.prank(distributor);
        she.fundRewards{value: amount}(amount * 1e6);
    }

    function backed() internal view {
        I.Accounting memory a = she.totalAccounting();
        assertEq(token.sharesOf(address(she)), a.activeRawShares + a.requestedRawShares + a.rewardRawShares);
    }

    function requestAdmissionState(address owner) internal view returns (bytes memory state) {
        (uint256 units, uint256 active, uint256 wrapped) = she.account(owner);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        state = abi.encode(she.totalAccounting(), she.getWithdrawalRequest(1), units, active, wrapped, stream, retained);
        state =
            abi.encode(state, token.sharesOf(address(she)), token.totalSupply(), overseer.burnCount(), she.isLocked());
    }

    function assertRequestRejected(address owner, uint256 units, bytes memory reason) internal {
        bytes memory before = requestAdmissionState(owner);
        vm.expectRevert(reason);
        vm.prank(owner);
        she.requestWithdrawal(units, 1);
        assertEq(requestAdmissionState(owner), before);
    }

    struct PayoutSnapshot {
        I.Accounting expectedAccounting;
        uint256 heldBefore;
        uint256 transferredShares;
        uint256 balanceBefore;
        uint256 upstreamBefore;
        uint256 count;
        uint256 totalSharesBefore;
        uint256 supplyBefore;
        uint256 pendingBefore;
        uint256 redeemedBefore;
        bytes ownerBefore;
    }

    function executeAndAssertPayout(address owner, uint256 id, uint256 expectedAmount) internal {
        PayoutSnapshot memory p;
        I.WithdrawalRequest memory withdrawal = she.getWithdrawalRequest(id);
        if (block.timestamp < withdrawal.eligibleAt) vm.warp(withdrawal.eligibleAt);
        assertEq(withdrawal.owner, owner);
        assertEq(uint256(withdrawal.status), uint256(I.RequestStatus.REQUESTED));
        assertFalse(she.isLocked());
        p.expectedAccounting = she.totalAccounting();
        p.heldBefore = token.sharesOf(address(she));
        p.transferredShares = expectedAmount * 1e6;
        assertEq(expectedAmount, withdrawal.rawShares / 1e6);
        assertLe(p.transferredShares, withdrawal.rawShares);
        uint256 leftover = withdrawal.rawShares - p.transferredShares;
        p.expectedAccounting.requestedRawShares -= withdrawal.rawShares;
        if (p.expectedAccounting.totalOwnershipUnits > SEED) p.expectedAccounting.activeRawShares += leftover;
        else p.expectedAccounting.rewardRawShares += leftover;
        p.balanceBefore = token.sharesOf(owner);
        p.upstreamBefore = address(overseer).balance;
        p.count = overseer.burnCount();
        p.totalSharesBefore = token.totalShares();
        p.supplyBefore = token.totalSupply();
        p.pendingBefore = overseer.totalPendingBurns();
        p.redeemedBefore = overseer.redeemed();
        (uint256 unitsBefore,,) = she.account(owner);
        p.ownerBefore = abi.encode(unitsBefore, owner.balance, wrapper.allowance(owner, address(she)));
        vm.prank(owner);
        uint256 paid = she.executeWithdrawal(id, expectedAmount);
        assertEq(paid, expectedAmount);
        assertEq(overseer.burnCount(), p.count);
        assertEq(token.sharesOf(owner), p.balanceBefore + p.transferredShares);
        assertEq(address(overseer).balance, p.upstreamBefore);
        assertEq(token.sharesOf(address(she)), p.heldBefore - p.transferredShares);
        assertEq(token.totalShares(), p.totalSharesBefore);
        assertEq(token.totalSupply(), p.supplyBefore);
        assertEq(overseer.totalPendingBurns(), p.pendingBefore);
        assertEq(overseer.redeemed(), p.redeemedBefore);
        assertEq(wrapper.allowance(address(she), address(overseer)), 0);
        (uint256 unitsAfter,,) = she.account(owner);
        assertEq(abi.encode(unitsAfter, owner.balance, wrapper.allowance(owner, address(she))), p.ownerBefore);
        assertEq(abi.encode(she.totalAccounting()), abi.encode(p.expectedAccounting));
        withdrawal.status = I.RequestStatus.EXECUTED;
        assertEq(abi.encode(she.getWithdrawalRequest(id)), abi.encode(withdrawal));
        assertFalse(she.isLocked());
        backed();
    }

    function donate(uint256 amount) internal {
        overseer.mint{value: amount}(address(this));
        assertTrue(wrapper.transfer(address(she), amount));
    }

    // Expected event snapshots derived before the action; independent event replay is in SheEvents.t.sol.
    function expectedAccount(uint256 units, I.Accounting memory accounting)
        internal
        pure
        returns (I.AccountBalance memory balance)
    {
        balance = I.AccountBalance(
            units, units == 0 ? 0 : Math.mulDiv(units, accounting.activeRawShares, accounting.totalOwnershipUnits)
        );
    }

    function emitExpectedDeposited(address payer, address beneficiary, uint256 amount, uint256 issued) internal {
        I.Accounting memory a = she.totalAccounting();
        (uint256 units,,) = she.account(beneficiary);
        a.activeRawShares += amount * 1e6;
        a.totalOwnershipUnits += issued + (a.totalOwnershipUnits == 0 ? SEED : 0);
        emit I.Deposited(payer, beneficiary, amount, issued, expectedAccount(units + issued, a), a);
    }

    function emitExpectedWithdrawalCancelled(uint256 id, address owner, uint256 raw, uint256 issued) internal {
        I.Accounting memory a = she.totalAccounting();
        (uint256 units,,) = she.account(owner);
        a.activeRawShares += raw;
        a.requestedRawShares -= raw;
        a.totalOwnershipUnits += issued;
        emit I.WithdrawalCancelled(id, owner, raw, issued, expectedAccount(units + issued, a), a);
    }

    function emitExpectedWithdrawalExecuted(uint256 id, uint256 amount) internal {
        I.WithdrawalRequest memory r = she.getWithdrawalRequest(id);
        I.Accounting memory a = she.totalAccounting();
        (uint256 units,,) = she.account(r.owner);
        a.requestedRawShares -= r.rawShares;
        uint256 remainder = r.rawShares - amount * 1e6;
        if (a.totalOwnershipUnits > SEED) a.activeRawShares += remainder;
        else a.rewardRawShares += remainder;
        emit I.WithdrawalExecuted(id, amount, r.owner, r.rawShares, expectedAccount(units, a), a);
    }

    function emitExpectedRewardsFunded(uint256 amount, uint256 received, uint256 scheduled, uint64 start, uint64 end)
        internal
    {
        I.Accounting memory a = she.totalAccounting();
        a.rewardRawShares += received;
        emit I.RewardsFunded(amount, received, scheduled, start, end, a);
    }

    function emitExpectedRewardsCheckpointed(uint256 allocated, uint256 retained) internal {
        (I.RewardStream memory stream,) = she.rewardState();
        emit I.RewardsCheckpointed(allocated, retained, stream.releasedRawShares, she.totalAccounting());
    }
}
