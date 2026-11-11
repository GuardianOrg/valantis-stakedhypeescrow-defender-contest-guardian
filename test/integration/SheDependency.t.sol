// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Fault injection for SHE's exact-transfer contract, not an additional supported production token.
// Keep real stHYPE custody and transfers so rollback assertions cover actual shares and allowances.
contract SheTransferDeltaWrapper {
    stHYPE public immutable sthype;
    uint256 public constant balanceToShareDecimals = 1e6;
    mapping(address => mapping(address => uint256)) public allowance;
    int256 public adjustment;
    uint256 public returnMode;
    int256 public transferAdjustment;
    uint256 public transferReturnMode;

    function configureTransfer(int256 delta, uint256 mode) external {
        transferAdjustment = delta;
        transferReturnMode = mode;
    }

    constructor(stHYPE token) {
        sthype = token;
    }

    function setAdjustment(int256 value) external {
        adjustment = value;
    }

    function setReturnMode(uint256 mode) external {
        returnMode = mode;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return sthype.sharesOf(owner) / 1e6;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        uint256 raw = amount * 1e6;
        raw = transferAdjustment < 0 ? raw - uint256(-transferAdjustment) : raw + uint256(transferAdjustment);
        sthype.transferShares(msg.sender, to, raw);
        if (transferReturnMode == 1) return false;
        if (transferReturnMode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        uint256 raw = amount * 1e6;
        raw = adjustment < 0 ? raw - uint256(-adjustment) : raw + uint256(adjustment);
        bool transferred = sthype.transferShares(from, to, raw);
        if (returnMode == 1) return false;
        if (returnMode == 2) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return transferred;
    }
}

contract SheDependencyTest is SheAssertions {
    function test_falseReturnAfterRealTransferRollsBackAndEmptyReturnAcceptsExactShares() public {
        SheTransferDeltaWrapper fault = new SheTransferDeltaWrapper(token);
        wrapper = wstHYPE(address(fault));
        token.grantRole(token.WRAPPER_ROLE(), address(fault));
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (params()))
                )
            )
        );
        deposit(alice, 10 ether);
        uint256 id = request(alice, 2 ether * 1e6);
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether);
        overseer.mint{value: 2 ether}(bob);
        vm.prank(bob);
        wrapper.approve(address(she), 2 ether);
        uint256 supply = token.totalSupply();
        uint256 shares = token.totalShares();
        bytes32 rewardsBefore = rewardSnapshot();
        assertEq(token.sharesOf(address(she)), 15 ether * 1e6);
        assertEq(wrapper.allowance(bob, address(she)), 2 ether);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(8 ether * 1e6, 8 ether * 1e6, 2 ether * 1e6, 4 ether * 1e6))
        );
        fault.setReturnMode(1);
        vm.expectCall(address(token), abi.encodeCall(stHYPE.transferShares, (bob, address(she), 1 ether * 1e6)));
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)),
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(wrapper))
        );
        assertEq(fault.returnMode(), 1);
        fault.setReturnMode(2);
        // An empty success response alone is insufficient: exact received shares must still be enforced.
        fault.setAdjustment(-1);
        reject(
            bob,
            0,
            abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__UnexpectedShareChange.selector)
        );
        fault.setAdjustment(0);
        vm.expectEmit(address(she));
        emitExpectedDeposited(bob, bob, 1 ether, 0.8 ether * 1e6);
        vm.prank(bob);
        (uint256 units, uint256 accepted) = she.deposit(1 ether, bob, 0.8 ether * 1e6, 1 ether);
        assertEq(units, 0.8 ether * 1e6);
        assertEq(accepted, 1 ether);
        (uint256 bobUnits, uint256 bobRaw, uint256 bobWrapped) = she.account(bob);
        assertEq(bobUnits, units);
        assertEq(bobRaw, 1 ether * 1e6);
        assertEq(bobWrapped, 1 ether);
        (uint256 aliceUnits,,) = she.account(alice);
        assertEq(aliceUnits, 8 ether * 1e6 - SEED);
        assertEq(wrapper.balanceOf(bob), 1 ether);
        assertEq(wrapper.allowance(bob, address(she)), 1 ether);
        assertEq(token.sharesOf(address(she)), 16 ether * 1e6);
        assertEq(token.totalSupply(), supply);
        assertEq(token.totalShares(), shares);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(11 ether * 1e6, 8.8 ether * 1e6, 2 ether * 1e6, 3 ether * 1e6))
        );
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);
        assertEq(rewardSnapshot(), rewardsBefore);
        assertFalse(she.isLocked());
        backed();
    }

    function test_unexpectedDepositShareDeltasRestoreFirstIssuanceAndExistingPoolState() public {
        SheTransferDeltaWrapper fault = new SheTransferDeltaWrapper(token);
        wrapper = wstHYPE(address(fault));
        token.grantRole(token.WRAPPER_ROLE(), address(fault));
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), upgradeGov, abi.encodeCall(StakedHypeEscrow.initialize, (params()))
                )
            )
        );
        for (uint256 seeded; seeded < 2; ++seeded) {
            uint256 state = vm.snapshot();
            if (seeded == 1) {
                deposit(alice, 10 ether);
                request(alice, 2 ether * 1e6);
                fund(4 ether);
                vm.warp(block.timestamp + 25);
            }
            donate(1 ether);
            overseer.mint{value: 2 ether}(bob);
            vm.prank(bob);
            wrapper.approve(address(she), 2 ether);
            uint256 custody = token.sharesOf(address(she));
            uint256 supply = token.totalSupply();
            int256[2] memory adjustments = [int256(-1), int256(1)];
            for (uint256 i; i < adjustments.length; ++i) {
                fault.setAdjustment(adjustments[i]);
                uint256 transferred = i == 0 ? 1 ether * 1e6 - 1 : 1 ether * 1e6 + 1;
                vm.expectCall(address(token), abi.encodeCall(stHYPE.transferShares, (bob, address(she), transferred)));
                reject(
                    bob,
                    0,
                    abi.encodeCall(I.deposit, (1 ether, bob, 0, 0)),
                    abi.encodeWithSelector(I.StakedHypeEscrow__UnexpectedShareChange.selector)
                );
                assertEq(fault.adjustment(), adjustments[i]);
            }
            fault.setAdjustment(0);
            uint256 expectedUnits = seeded == 0 ? 1 ether * 1e6 - SEED : uint256(1 ether * 1e6) * 8 / 10;
            vm.prank(bob);
            (uint256 units, uint256 accepted) = she.deposit(1 ether, bob, expectedUnits, 1 ether);
            assertEq(units, expectedUnits);
            assertEq(accepted, 1 ether);
            assertEq(wrapper.balanceOf(bob), 1 ether);
            assertEq(wrapper.allowance(bob, address(she)), 1 ether);
            assertEq(token.sharesOf(address(she)), custody + 1 ether * 1e6);
            assertEq(token.totalSupply(), supply);
            assertEq(storedAccounting().activeRawShares, uint256(seeded == 0 ? 1 ether : 11 ether) * 1e6);
            assertEq(storedAccounting().totalOwnershipUnits, (seeded == 0 ? SEED : 8 ether * 1e6) + expectedUnits);
            assertEq(storedAccounting().requestedRawShares, seeded == 0 ? 0 : 2 ether * 1e6);
            assertEq(storedAccounting().rewardRawShares, uint256(seeded == 0 ? 1 ether : 3 ether) * 1e6);
            (uint256 seedUnits,,) = she.account(address(1));
            assertEq(seedUnits, SEED);
            backed();
            assertTrue(vm.revertTo(state));
        }
    }
}
