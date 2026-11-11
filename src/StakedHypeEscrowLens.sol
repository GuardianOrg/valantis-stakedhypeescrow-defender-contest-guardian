// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStakedHypeEscrow} from "./interfaces/IStakedHypeEscrow.sol";
import {IStakedHypeEscrowToken} from "./interfaces/IStakedHypeEscrowDependencies.sol";

/**
 * @title StakedHypeEscrowLens
 * @notice Read-only quotes for off-chain StakedHypeEscrow integrations.
 * @dev Stateless and deployed directly. Pass the escrow proxy to each helper.
 *      Quotes reflect current state; they do not guarantee transaction success.
 */
contract StakedHypeEscrowLens {
    /**
     *
     *  VIEW FUNCTIONS
     *
     */
    /**
     * @notice Quotes ownership units and the wstHYPE charge for a deposit.
     * @dev Initial user issuance excludes the permanent seed. Returns zero units/charge when that initial
     *      entitlement is below one nominal stHYPE wei or one wstHYPE wei. Other execution conditions still apply.
     * @param escrow The StakedHypeEscrow proxy.
     * @param maxAmountWstHype Maximum wstHYPE base units offered by the payer.
     * @return ownershipUnits Active units to issue.
     * @return acceptedWstHype wstHYPE base units to transfer into escrow.
     * @return unspentWstHype Offered wstHYPE base units left with the payer.
     */
    function previewDeposit(IStakedHypeEscrow escrow, uint256 maxAmountWstHype)
        external
        view
        returns (uint256 ownershipUnits, uint256 acceptedWstHype, uint256 unspentWstHype)
    {
        IStakedHypeEscrow.Accounting memory accounting = escrow.totalAccounting();
        uint256 rawShareQuantum = escrow.RAW_SHARES_PER_WSTHYPE_WEI();
        uint256 acceptedRawShares;
        (ownershipUnits, acceptedRawShares) = escrow.quoteEntry(
            maxAmountWstHype * rawShareQuantum, accounting.activeRawShares, accounting.totalOwnershipUnits
        );
        if (
            accounting.totalOwnershipUnits == 0 && ownershipUnits != 0
                && (ownershipUnits < rawShareQuantum
                    || IStakedHypeEscrowToken(escrow.configuration().stHype).sharesToBalance(ownershipUnits) == 0)
        ) {
            return (0, 0, maxAmountWstHype);
        }
        acceptedWstHype = acceptedRawShares / rawShareQuantum;
        unspentWstHype = maxAmountWstHype - acceptedWstHype;
    }

    /**
     * @notice Quotes requested shares at the current active pool rate.
     * @param escrow The StakedHypeEscrow proxy.
     * @param owner The position owner; cannot be the permanently locked seed holder.
     * @param ownershipUnits Active units to remove.
     * @return rawShares Raw stHYPE shares to reserve under a new cooldown.
     */
    function previewRequestWithdrawal(IStakedHypeEscrow escrow, address owner, uint256 ownershipUnits)
        external
        view
        returns (uint256 rawShares)
    {
        require(owner != escrow.SEED_OWNER(), IStakedHypeEscrow.StakedHypeEscrow__InvalidAddress());
        (uint256 ownerUnits,,) = escrow.account(owner);
        require(ownershipUnits <= ownerUnits, IStakedHypeEscrow.StakedHypeEscrow__InsufficientUnits());

        IStakedHypeEscrow.Accounting memory accounting = escrow.totalAccounting();
        if (ownershipUnits != 0) {
            rawShares = Math.mulDiv(ownershipUnits, accounting.activeRawShares, accounting.totalOwnershipUnits);
        }
    }

    /**
     * @notice Quotes active units issued when a pending withdrawal is cancelled at the current pool price.
     * @dev Returns zero for unknown or resolved requests, or shares too small to issue a unit.
     *      Caller authorization, pause state and the caller's minimum still apply to cancellation.
     * @param escrow The StakedHypeEscrow proxy.
     * @param requestId Withdrawal request to quote.
     * @return ownershipUnits Active units issued to the owner, rounded down.
     */
    function previewCancelWithdrawal(IStakedHypeEscrow escrow, uint256 requestId)
        external
        view
        returns (uint256 ownershipUnits)
    {
        IStakedHypeEscrow.WithdrawalRequest memory withdrawal = escrow.getWithdrawalRequest(requestId);
        if (withdrawal.status != IStakedHypeEscrow.RequestStatus.REQUESTED) {
            return 0;
        }
        IStakedHypeEscrow.Accounting memory accounting = escrow.totalAccounting();
        ownershipUnits = Math.mulDiv(withdrawal.rawShares, accounting.totalOwnershipUnits, accounting.activeRawShares);
    }

    /**
     * @notice Quotes execution timing and the wstHYPE returned to a request's owner.
     * @dev Anyone may execute. Eligibility covers request status, maturity and SHE pause state.
     *      Minimum output and token transfer conditions still apply. No Overseer liquidity read is needed.
     * @param escrow The StakedHypeEscrow proxy.
     * @param requestId Withdrawal request to quote.
     * @return sheEligible Whether the request passes SHE's status, clock and pause conditions.
     * @return amountWstHype wstHYPE base units transferred on execution, rounded down from reserved raw shares.
     */
    function previewExecution(IStakedHypeEscrow escrow, uint256 requestId)
        external
        view
        returns (bool sheEligible, uint256 amountWstHype)
    {
        IStakedHypeEscrow.WithdrawalRequest memory withdrawal = escrow.getWithdrawalRequest(requestId);
        if (withdrawal.status != IStakedHypeEscrow.RequestStatus.REQUESTED) {
            return (false, 0);
        }
        sheEligible = !escrow.paused() && block.timestamp >= withdrawal.eligibleAt;
        amountWstHype = withdrawal.rawShares / escrow.RAW_SHARES_PER_WSTHYPE_WEI();
    }
}
