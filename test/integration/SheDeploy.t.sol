// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {StakedHypeEscrowDeployScript} from "../../script/StakedHypeEscrowDeploy.s.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {StakedHypeEscrowLens} from "../../src/StakedHypeEscrowLens.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";
import {Overseer} from "../../src/Overseer.sol";

// Local implementations at the README addresses; this is not a mainnet fork or a live deployment.
contract SheDeployTest is Test {
    address private constant STHYPE = 0xfFaa4a3D97fE9107Cef8a3F48c069F577Ff76cC1;
    address private constant WSTHYPE = 0x94e8396e0869c9F2200760aF0621aFd240E1CF38;
    address private constant OVERSEER = 0xB96f07367e69e86d6e9C3F29215885104813eeAE;
    address private constant MULTISIG = 0x97dEe0eA4Ca10560f260A0f6f45bdC128A1D51f9;
    address private constant TIMELOCK = 0xc5DEd4F7F53919c714059a17d31371aE847E23D2;
    uint256 private constant DEPOSIT = 0.01 ether;
    uint256 private constant G = 1e6;
    address private manager = address(0x2001);
    address private distributor = address(0x2002);
    address private deployer;
    StakedHypeEscrowDeployScript private deployment;
    stHYPE private token;
    wstHYPE private wrapper;
    Overseer private overseer;

    function setUp() public {
        vm.chainId(999);
        vm.warp(1000);
        vm.roll(100);
        vm.deal(address(this), 1 ether);
        // Public fixture key only. No environment file or real deployment credentials are used.
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        vm.setEnv("SHE_MANAGER", vm.toString(manager));
        vm.setEnv("SHE_REWARD_DISTRIBUTOR", vm.toString(distributor));
        deployer = vm.addr(1);
        vm.deal(deployer, 1 ether);

        vm.etch(STHYPE, address(new stHYPE()).code);
        vm.etch(WSTHYPE, address(new wstHYPE()).code);
        vm.etch(OVERSEER, address(new Overseer()).code);
        token = stHYPE(STHYPE);
        wrapper = wstHYPE(WSTHYPE);
        overseer = Overseer(payable(OVERSEER));
        token.initialize(address(this), OVERSEER, WSTHYPE);
        wrapper.initialize("Staked HYPE Shares", "wstHYPE", 18, address(this), STHYPE);
        overseer.initialize(address(this), STHYPE, address(0), address(0));
        overseer.initializeV3();
        overseer.mint{value: 0.02 ether}(address(1));
        overseer.mint{value: DEPOSIT}(deployer);
        deployment = new StakedHypeEscrowDeployScript();
    }

    // vm.setEnv is process-wide, so keep scenarios that change these variables sequential.
    function test_deploymentPreflightAndBootstrap() public {
        checkOtherChainsRejected();
        checkInsufficientBalanceRejected();
        checkZeroOperationalRolesRejected();
        checkExcessBalance();
        checkExactMinimumBalance();
    }

    function checkExactMinimumBalance() private {
        assertEq(wrapper.balanceOf(deployer), DEPOSIT);
        assertDeployment();
        assertEq(wrapper.balanceOf(deployer), 0);
    }

    function checkExcessBalance() private {
        overseer.mint{value: DEPOSIT}(deployer);
        assertDeployment();
        assertEq(wrapper.balanceOf(deployer), DEPOSIT);
    }

    function checkInsufficientBalanceRejected() private {
        vm.prank(deployer);
        wrapper.transfer(address(0xB0B), 1);
        assertEq(wrapper.balanceOf(deployer), DEPOSIT - 1);
        assertRejected("Deployer needs at least 0.01 wstHYPE");
        vm.prank(address(0xB0B));
        wrapper.transfer(deployer, 1);
        assertEq(wrapper.balanceOf(deployer), DEPOSIT);
    }

    function checkOtherChainsRejected() private {
        vm.chainId(998);
        assertRejected("Only HyperEVM mainnet");
        vm.chainId(1);
        assertRejected("Only HyperEVM mainnet");
        vm.chainId(999);
    }

    function checkZeroOperationalRolesRejected() private {
        vm.setEnv("SHE_MANAGER", vm.toString(address(0)));
        assertRejected("Zero role address");
        vm.setEnv("SHE_MANAGER", vm.toString(manager));
        vm.setEnv("SHE_REWARD_DISTRIBUTOR", vm.toString(address(0)));
        assertRejected("Zero role address");
        vm.setEnv("SHE_REWARD_DISTRIBUTOR", vm.toString(distributor));
    }

    function assertDeployment() private {
        uint256 walletBefore = token.sharesOf(deployer);
        uint256 supplyBefore = token.totalSupply();
        uint256 sharesBefore = token.totalShares();
        uint256 backingBefore = address(overseer).balance;
        (StakedHypeEscrow she, StakedHypeEscrowLens lens) = deployment.run();

        assertConfiguration(she, lens);
        assertBootstrap(she, lens);
        assertEq(token.sharesOf(address(she)), DEPOSIT * G);
        assertEq(token.sharesOf(deployer), walletBefore - DEPOSIT * G);
        assertEq(wrapper.allowance(deployer, address(she)), 0);
        assertEq(wrapper.allowance(address(she), OVERSEER), 0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.totalShares(), sharesBefore);
        assertEq(address(overseer).balance, backingBefore);
        assertEq(overseer.burnCount(), 2);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(overseer.protocolPendingFee(), 0);
    }

    function assertConfiguration(StakedHypeEscrow she, StakedHypeEscrowLens lens) private view {
        assertGt(address(she).code.length, 0);
        assertGt(address(lens).code.length, 0);
        assertTrue(address(she) != address(lens));
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address implementation = address(uint160(uint256(vm.load(address(she), implementationSlot))));
        assertGt(implementation.code.length, 0);
        assertTrue(implementation != address(she));
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        ProxyAdmin proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(she), adminSlot)))));
        assertEq(proxyAdmin.owner(), TIMELOCK);
        assertEq(
            abi.encode(she.configuration()), abi.encode(I.Configuration(STHYPE, WSTHYPE, OVERSEER, 30 days, 23 hours))
        );
        assertEq(she.defaultAdmin(), MULTISIG);
        assertEq(she.defaultAdminDelay(), 2 days);
        assertTrue(she.hasRole(she.DEFAULT_ADMIN_ROLE(), MULTISIG));
        assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
        assertTrue(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        assertFalse(she.hasRole(she.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(she.hasRole(she.MANAGER_ROLE(), deployer));
        assertFalse(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), deployer));
    }

    function assertBootstrap(StakedHypeEscrow she, StakedHypeEscrowLens lens) private {
        assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(DEPOSIT * G, DEPOSIT * G, 0, 0)));
        (uint256 units, uint256 active, uint256 wrapped) = she.account(deployer);
        assertEq(units, DEPOSIT * G - 1000);
        assertEq(active, DEPOSIT * G - 1000);
        assertEq(wrapped, DEPOSIT - 1);
        (uint256 seedUnits, uint256 seedRaw,) = she.account(address(1));
        assertEq(seedUnits, 1000);
        assertEq(seedRaw, 1000);
        assertFalse(she.paused());
        assertFalse(she.isLocked());
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(abi.encode(stream), abi.encode(I.RewardStream(0, 0, 0, 0)));
        assertEq(retained, 0);
        assertEq(lens.previewRequestWithdrawal(she, deployer, units), DEPOSIT * G - 1000);
        she.checkpointRewards();
        assertEq(abi.encode(she.totalAccounting()), abi.encode(I.Accounting(DEPOSIT * G, DEPOSIT * G, 0, 0)));
    }

    function assertRejected(string memory reason) private {
        uint64 nonceBefore = vm.getNonce(deployer);
        bytes32 beforeState = tokenSnapshot();
        vm.expectRevert(abi.encodeWithSignature("Error(string)", reason));
        deployment.run();
        assertEq(vm.getNonce(deployer), nonceBefore);
        assertEq(tokenSnapshot(), beforeState);
    }

    function tokenSnapshot() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.totalShares(),
                token.sharesOf(deployer),
                deployer.balance,
                address(overseer).balance,
                overseer.getAllBurns()
            )
        );
    }
}
