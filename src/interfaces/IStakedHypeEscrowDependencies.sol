// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice stHYPE share balance and conversion methods used by the escrow.
 */
interface IStakedHypeEscrowToken {
    function sharesOf(address account) external view returns (uint256);

    function sharesToBalance(uint256 shares) external view returns (uint256);
}

/**
 * @notice wstHYPE transfers and underlying-token configuration.
 */
interface IStakedHypeEscrowWrapper is IERC20 {
    function sthype() external view returns (address);

    function balanceToShareDecimals() external view returns (uint256);
}

/**
 * @notice Overseer configuration and reward funding methods used by the escrow.
 */
interface IStakedHypeEscrowOverseer {
    function sthype() external view returns (address);

    function mint(address to) external payable returns (uint256);
}
