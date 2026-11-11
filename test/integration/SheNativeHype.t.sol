// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {Overseer} from "../../src/Overseer.sol";

contract SheForceNativeHype {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

contract SheRejectingBookkeepingRecipient {
    error BookkeepingRejected();
    uint256 public credited;

    receive() external payable {
        credited += msg.value;
        revert BookkeepingRejected();
    }
}

contract SheNativeHypeTest is SheAssertions {
    function test_nativeBookkeepingIsNotCalledForWstHypeWithdrawal() public {
        SheRejectingBookkeepingRecipient recipient = new SheRejectingBookkeepingRecipient();
        uint256 id = request(address(recipient), deposit(address(recipient), 10 ether));
        fund(2 ether);
        executeAndAssertPayout(address(recipient), id, 10 ether - 1);
        assertEq(recipient.credited(), 0);
        assertEq(address(recipient).balance, 0);
    }

    function test_forcedNativeHypeCreatesNoEntitlementAndDoesNotAffectFundingOrExit() public {
        deposit(alice, 10 ether);
        uint256 id = request(alice, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        bytes memory accounting = abi.encode(storedAccounting(), she.totalAccounting());
        bytes memory original = abi.encode(she.getWithdrawalRequest(id));
        bytes32 stream = rewardSnapshot();
        bytes memory position = positionState();
        uint256 shares = token.totalShares();
        uint256 supply = token.totalSupply();
        uint256 held = token.sharesOf(address(she));
        uint256 upstream = address(overseer).balance;
        new SheForceNativeHype{value: 7 ether}(payable(address(she)));
        assertEq(address(she).balance, 7 ether);
        assertEq(abi.encode(storedAccounting(), she.totalAccounting()), accounting);
        assertEq(rewardSnapshot(), stream);
        assertEq(positionState(), position);
        assertEq(token.totalShares(), shares);
        assertEq(token.totalSupply(), supply);
        assertEq(token.sharesOf(address(she)), held);
        assertEq(address(overseer).balance, upstream);
        assertEq(abi.encode(she.getWithdrawalRequest(id)), original);
        she.checkpointRewards();
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(9 ether * 1e6, 8 ether * 1e6, 2 ether * 1e6, 3 ether * 1e6))
        );
        executeAndAssertPayout(alice, id, 2 ether);
        assertEq(address(she).balance, 7 ether);
        (I.RewardStream memory previous,) = she.rewardState();
        vm.warp(previous.end);
        upstream = address(overseer).balance;
        uint256 distributorBalance = distributor.balance;
        vm.expectCall(address(overseer), 1 ether, abi.encodeWithSignature("mint(address)", address(she)), uint64(1));
        fund(1 ether);
        assertEq(address(overseer).balance, upstream + 1 ether);
        assertEq(distributor.balance, distributorBalance - 1 ether);
        assertEq(address(she).balance, 7 ether);
        assertEq(token.sharesOf(address(she)), held - 1 ether * 1e6);
        assertEq(token.totalShares(), shares + 1 ether * 1e6);
        assertEq(token.totalSupply(), supply + 1 ether);
        assertEq(
            abi.encode(storedAccounting()), abi.encode(I.Accounting(12 ether * 1e6, 8 ether * 1e6, 0, 1 ether * 1e6))
        );
        (I.RewardStream memory next, uint256 retained) = she.rewardState();
        assertEq(abi.encode(next), abi.encode(I.RewardStream(1 ether * 1e6, 0, previous.end, previous.end + 100)));
        assertEq(retained, 0);
        uint256 freshId = request(alice, 1 ether * 1e6);
        assertEq(she.getWithdrawalRequest(freshId).rawShares, 1.5 ether * 1e6);
        executeAndAssertPayout(alice, freshId, 1.5 ether);
        assertEq(address(she).balance, 7 ether);
        assertEq(wrapper.balanceOf(alice), 3.5 ether);
        backed();
    }

    function positionState() private view returns (bytes memory) {
        (uint256 units, uint256 raw, uint256 wrapped) = she.account(alice);
        return abi.encode(units, raw, wrapped);
    }
}
