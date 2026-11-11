// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SheAssertions} from "../helpers/SheAssertions.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {Overseer} from "../../src/Overseer.sol";
import {SheTransferDeltaWrapper} from "./SheDependency.t.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Fault injection for funding: the adapter has explicit share-transfer authority in this fixture.
contract SheFaultyOverseer {
    stHYPE public immutable sthype;
    Overseer immutable upstream;
    uint256 public calls;
    uint256 public excessShares;
    bool public skipMint;

    constructor(stHYPE token, Overseer overseer) {
        sthype = token;
        upstream = overseer;
    }

    function configure(uint256 excess, bool skip) external {
        excessShares = excess;
        skipMint = skip;
    }

    function mint(address to) external payable returns (uint256) {
        ++calls;
        if (excessShares != 0) sthype.transferShares(to, address(this), excessShares);
        if (!skipMint) upstream.mint{value: msg.value}(to);
        return type(uint256).max;
    }
}

contract SheSettlementGuardsTest is SheAssertions {
    SheFaultyOverseer fault;

    function test_requestsRequireOneTransferableWstHypeWeiAtAnAppreciatedRate() public {
        deposit(alice, 10 ether);
        uint256 supply = token.totalSupply() * 2;
        vm.deal(address(overseer), supply);
        token.syncSupply(supply, 0);
        assertEq(token.sharesToBalance(1e6 - 1), 1);
        reject(
            alice,
            0,
            abi.encodeCall(I.requestWithdrawal, (1e6 - 1, 0)),
            abi.encodeWithSelector(I.StakedHypeEscrow__InvalidAmount.selector)
        );
        uint256 id = request(alice, 1e6);
        executeAndAssertPayout(alice, id, 1);
        assertEq(token.balanceOf(alice), 2);
    }

    function installFault() private {
        fault = new SheFaultyOverseer(token, overseer);
        token.grantRole(token.WRAPPER_ROLE(), address(fault));
        extraActors.push(address(fault));
        I.InitializationParams memory p = params();
        p.configuration.overseer = address(fault);
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(address(implementation), upgradeGov, abi.encodeCall(I.initialize, (p)))
            )
        );
    }

    function prepareExit() private returns (uint256 id) {
        installFault();
        deposit(alice, 10 ether);
        deposit(bob, 10 ether);
        id = request(alice, 6 ether * 1e6);
        request(bob, 2 ether * 1e6);
        fund(4 ether);
        vm.warp(block.timestamp + 25);
        donate(1 ether);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(12 ether * 1e6, 12 ether * 1e6, 8 ether * 1e6, 4 ether * 1e6))
        );
        assertEq(token.sharesOf(address(she)), 25 ether * 1e6);
        assertEq(alice.balance, 0);
        assertEq(fault.calls(), 1);
    }

    function test_fundingRejectsZeroOrNegativeReceivedSharesAndMeasuresSuccessfulMint() public {
        prepareExit();
        vm.warp(1100);
        bytes memory other = abi.encode(she.getWithdrawalRequest(2));
        uint256 supply = token.totalSupply();
        uint256 totalShares = token.totalShares();
        uint256 distributorBalance = distributor.balance;
        uint256 upstreamBalance = address(overseer).balance;
        for (uint256 excess; excess < 2; ++excess) {
            fault.configure(excess, true);
            reject(
                distributor,
                1 ether,
                abi.encodeCall(I.fundRewards, (0)),
                abi.encodeWithSelector(I.StakedHypeEscrow__UnexpectedShareChange.selector)
            );
            assertEq(fault.calls(), 1);
        }
        fault.configure(0, false);
        vm.expectEmit(address(she));
        emitExpectedRewardsFunded(1 ether, 1 ether * 1e6, 1 ether * 1e6, 1100, 1200);
        fund(1 ether);
        assertEq(fault.calls(), 2);
        assertEq(address(fault).balance, 0);
        assertEq(token.sharesOf(address(fault)), 0);
        assertEq(distributor.balance, distributorBalance - 1 ether);
        assertEq(address(overseer).balance, upstreamBalance + 1 ether);
        assertEq(token.totalSupply(), supply + 1 ether);
        assertEq(token.totalShares(), totalShares + 1 ether * 1e6);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(17 ether * 1e6, 12 ether * 1e6, 8 ether * 1e6, 1 ether * 1e6))
        );
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(abi.encode(stream), abi.encode(I.RewardStream(1 ether * 1e6, 0, 1100, 1200)));
        assertEq(retained, 0);
        assertEq(abi.encode(she.getWithdrawalRequest(2)), other);
        assertFalse(she.isLocked());
        backed();
    }

    function test_transferFailuresRestoreAllBucketsCustodyAndRequestThenRetry() public {
        SheTransferDeltaWrapper transferFault = new SheTransferDeltaWrapper(token);
        wrapper = wstHYPE(address(transferFault));
        token.grantRole(token.WRAPPER_ROLE(), address(transferFault));
        uint256 id = prepareExit();
        bytes memory other = abi.encode(she.getWithdrawalRequest(2));
        int256[3] memory deltas = [int256(-1), int256(1), int256(0)];
        for (uint256 i; i < deltas.length; ++i) {
            transferFault.configureTransfer(deltas[i], i == 2 ? 1 : 0);
            bytes memory reason = i == 2
                ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(wrapper))
                : abi.encodeWithSelector(I.StakedHypeEscrow__UnexpectedShareChange.selector);
            uint256 raw = i == 0 ? 6 ether * 1e6 - 1 : i == 1 ? 6 ether * 1e6 + 1 : 6 ether * 1e6;
            vm.expectCall(address(token), abi.encodeCall(stHYPE.transferShares, (address(she), alice, raw)));
            reject(alice, 0, abi.encodeCall(I.executeWithdrawal, (id, 6 ether)), reason);
            assertEq(fault.calls(), 1);
        }
        // Empty success data still requires the exact share debit.
        transferFault.configureTransfer(-1, 2);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 6 ether)),
            abi.encodeWithSelector(I.StakedHypeEscrow__UnexpectedShareChange.selector)
        );
        transferFault.configureTransfer(0, 2);
        executeAndAssertPayout(alice, id, 6 ether);
        assertEq(fault.calls(), 1, "execution called Overseer");
        assertEq(abi.encode(she.getWithdrawalRequest(2)), other);
        assertEq(
            abi.encode(storedAccounting()),
            abi.encode(I.Accounting(14 ether * 1e6, 12 ether * 1e6, 2 ether * 1e6, 3 ether * 1e6))
        );
    }

    function test_pausedTokenTransferRollsBackAndOriginalRequestRetries() public {
        uint256 id = prepareExit();
        token.pauseTransfer(true);
        reject(
            alice,
            0,
            abi.encodeCall(I.executeWithdrawal, (id, 6 ether)),
            abi.encodeWithSelector(stHYPE.TransferIsPaused.selector)
        );
        token.pauseTransfer(false);
        executeAndAssertPayout(alice, id, 6 ether);
        assertEq(fault.calls(), 1);
    }
}
