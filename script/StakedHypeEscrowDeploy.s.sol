// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StakedHypeEscrow} from "../src/StakedHypeEscrow.sol";
import {StakedHypeEscrowLens} from "../src/StakedHypeEscrowLens.sol";
import {IStakedHypeEscrow} from "../src/interfaces/IStakedHypeEscrow.sol";

/// @notice Deploys SHE and its Lens on HyperEVM mainnet and deposits 0.01 wstHYPE for the deployer.
/// @dev Requires DEPLOYER_PRIVATE_KEY, SHE_MANAGER and SHE_REWARD_DISTRIBUTOR.
contract StakedHypeEscrowDeployScript is Script {
    // Production addresses from README.md. Upgrade ownership is separate from SHE's default admin.
    address internal constant STHYPE_PROXY = 0xfFaa4a3D97fE9107Cef8a3F48c069F577Ff76cC1;
    address internal constant WSTHYPE_PROXY = 0x94e8396e0869c9F2200760aF0621aFd240E1CF38;
    address internal constant OVERSEER_PROXY = 0xB96f07367e69e86d6e9C3F29215885104813eeAE;
    address internal constant OWNER_MULTISIG = 0x97dEe0eA4Ca10560f260A0f6f45bdC128A1D51f9;
    address internal constant UPGRADE_TIMELOCK = 0xc5DEd4F7F53919c714059a17d31371aE847E23D2;
    uint256 internal constant INITIAL_DEPOSIT = 0.01 ether; // wstHYPE has 18 decimals.

    function run() external returns (StakedHypeEscrow she, StakedHypeEscrowLens lens) {
        require(block.chainid == 999, "Only HyperEVM mainnet");

        address manager = vm.envAddress("SHE_MANAGER");
        address rewardDistributor = vm.envAddress("SHE_REWARD_DISTRIBUTOR");
        require(manager != address(0) && rewardDistributor != address(0), "Zero role address");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        IERC20 wstHype = IERC20(WSTHYPE_PROXY);
        require(wstHype.balanceOf(deployer) >= INITIAL_DEPOSIT, "Deployer needs at least 0.01 wstHYPE");

        IStakedHypeEscrow.InitializationParams memory params = IStakedHypeEscrow.InitializationParams({
            configuration: IStakedHypeEscrow.Configuration({
                stHype: STHYPE_PROXY,
                wstHype: WSTHYPE_PROXY,
                overseer: OVERSEER_PROXY,
                cooldown: 30 days,
                rewardDuration: 23 hours
            }),
            defaultAdmin: OWNER_MULTISIG,
            manager: manager,
            rewardDistributor: rewardDistributor,
            defaultAdminDelay: 2 days
        });

        vm.startBroadcast(deployerPrivateKey);
        StakedHypeEscrow implementation = new StakedHypeEscrow();
        she = StakedHypeEscrow(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), UPGRADE_TIMELOCK, abi.encodeCall(StakedHypeEscrow.initialize, (params))
                )
            )
        );
        require(wstHype.approve(address(she), INITIAL_DEPOSIT), "wstHYPE approval failed");
        // First issuance is 1e6 ownership units per wstHYPE wei, less the permanent seed.
        uint256 minOwnershipUnits = INITIAL_DEPOSIT * 1e6 - she.SEED_OWNERSHIP_UNITS();
        she.deposit(INITIAL_DEPOSIT, deployer, minOwnershipUnits, INITIAL_DEPOSIT);
        lens = new StakedHypeEscrowLens();
        vm.stopBroadcast();

        console.log("SHE implementation:", address(implementation));
        console.log("SHE proxy:", address(she));
        console.log("SHE Lens:", address(lens));
        console.log("Initial deposit beneficiary:", deployer);
    }
}
