// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IStakedHypeEscrow
 * @notice Interface for wstHYPE custody, streamed premiums and delayed withdrawals.
 */
interface IStakedHypeEscrow {
    /**
     *
     *  ENUMS
     *
     */
    enum RequestStatus {
        NONE,
        REQUESTED,
        EXECUTED,
        CANCELLED
    }

    /**
     *
     *  STRUCTS
     *
     */

    struct Configuration {
        address stHype;
        address wstHype;
        address overseer;
        // Duration for new requests, from 1 second through 180 days inclusive; mutable by the default admin.
        uint64 cooldown;
        // Duration for new streams, from 1 second through 7 days inclusive; mutable by the default admin.
        uint64 rewardDuration;
    }

    struct InitializationParams {
        Configuration configuration;
        address defaultAdmin;
        address manager;
        address rewardDistributor;
        uint48 defaultAdminDelay;
    }

    struct RewardStream {
        uint256 totalRawShares;
        // Includes elapsed emissions retained when no user units remain outside the permanent seed.
        uint256 releasedRawShares;
        uint64 start;
        uint64 end;
    }

    struct WithdrawalRequest {
        address owner;
        uint256 rawShares;
        uint64 requestedAt;
        uint64 eligibleAt;
        RequestStatus status;
    }

    /// @dev All asset buckets use raw stHYPE shares. Active assets and total units include the permanent seed.
    struct Accounting {
        uint256 activeRawShares;
        uint256 totalOwnershipUnits;
        uint256 requestedRawShares;
        uint256 rewardRawShares;
    }

    /// @dev Active position at the emitted accounting snapshot; pending requests are tracked separately.
    struct AccountBalance {
        uint256 ownershipUnits;
        uint256 activeRawShares;
    }

    /**
     *
     *  EVENTS
     *
     */

    /// @dev Accounting events carry absolute balances after the described change, not additional deltas.
    ///      Reward checkpoints inside an operation precede its final event. Pool balances include the seed.
    event Deposited(
        address indexed payer,
        address indexed beneficiary,
        uint256 amountWstHype,
        uint256 ownershipUnits,
        AccountBalance account,
        Accounting accounting
    );

    /// @dev Emitted once, with the same final pool totals as the first Deposited event.
    event SeedLocked(address indexed owner, uint256 ownershipUnits, AccountBalance account, Accounting accounting);

    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        uint256 ownershipUnits,
        uint256 rawShares,
        uint64 eligibleAt,
        AccountBalance account,
        Accounting accounting
    );

    /// @dev rawShares is the entire resolved request, including any rounding remainder retained by SHE.
    event WithdrawalExecuted(
        uint256 indexed requestId,
        uint256 amountWstHype,
        address indexed owner,
        uint256 rawShares,
        AccountBalance account,
        Accounting accounting
    );

    event WithdrawalCancelled(
        uint256 indexed requestId,
        address indexed owner,
        uint256 rawShares,
        uint256 ownershipUnits,
        AccountBalance account,
        Accounting accounting
    );

    event RewardsFunded(
        uint256 amountHype,
        uint256 receivedRawShares,
        uint256 scheduledRawShares,
        uint64 start,
        uint64 end,
        Accounting accounting
    );

    /// @dev releasedRawShares is cumulative elapsed release for the current stream, including retained emissions.
    ///      The first two fields are deltas for this checkpoint, including newly recognized surplus.
    event RewardsCheckpointed(
        uint256 allocatedRawShares, uint256 undistributedRawShares, uint256 releasedRawShares, Accounting accounting
    );
    /// @dev amount is the ERC20 transfer argument; the recipient's net receipt depends on the token.
    event TokensRescued(address indexed token, address indexed recipient, uint256 amount);
    event PausedSet(bool paused);
    event CooldownSet(uint64 cooldown);
    event RewardDurationSet(uint64 rewardDuration);
    event EscrowConfigured(address stHype, address wstHype, address overseer, uint64 cooldown, uint64 rewardDuration);

    /**
     *
     *  ERRORS
     *
     */

    error StakedHypeEscrow__InvalidConfiguration();
    error StakedHypeEscrow__InvalidAddress();
    error StakedHypeEscrow__InvalidAmount();
    error StakedHypeEscrow__ProtectedToken();
    error StakedHypeEscrow__MinimumNotMet();
    error StakedHypeEscrow__InsufficientUnits();
    error StakedHypeEscrow__InvalidRequest();
    error StakedHypeEscrow__OnlyRequestOwner();
    error StakedHypeEscrow__Paused();
    error StakedHypeEscrow__CooldownNotElapsed();
    error StakedHypeEscrow__StreamActive();
    error StakedHypeEscrow__UnexpectedShareChange();
    error StakedHypeEscrow__AccountingInvariant();

    /**
     *
     *  VIEW FUNCTIONS
     *
     */

    function RAW_SHARES_PER_WSTHYPE_WEI() external view returns (uint256);

    /// @notice Non-withdrawable holder of the fixed ownership seed; cannot receive deposits.
    function SEED_OWNER() external view returns (address);

    /// @notice Units permanently allocated from the first successful deposit's issuance.
    function SEED_OWNERSHIP_UNITS() external view returns (uint256);

    /// @notice Maximum cooldown for new withdrawal requests, in seconds.
    function MAX_COOLDOWN() external view returns (uint64);

    /// @notice Maximum duration for new reward streams, in seconds.
    function MAX_REWARD_DURATION() external view returns (uint64);

    function configuration() external view returns (Configuration memory);

    /// @notice Global security pause for deposits, withdrawal requests, cancellations and executions.
    function paused() external view returns (bool);

    function isLocked() external view returns (bool);

    function totalAccounting() external view returns (Accounting memory);

    function account(address owner)
        external
        view
        returns (uint256 ownershipUnits, uint256 activeRawShares, uint256 activeWstHype);

    function rewardState() external view returns (RewardStream memory stream, uint256 undistributedRawShares);

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory);

    function quoteEntry(uint256 maxRawShares, uint256 activeRawShares, uint256 totalOwnershipUnits)
        external
        pure
        returns (uint256 ownershipUnits, uint256 acceptedRawShares);

    /**
     *
     *  EXTERNAL FUNCTIONS
     *
     */

    function initialize(InitializationParams calldata params) external;

    function deposit(
        uint256 maxAmountWstHype,
        address beneficiary,
        uint256 minOwnershipUnits,
        uint256 minAmountWstHypeAccepted
    ) external returns (uint256 ownershipUnits, uint256 acceptedWstHype);

    function requestWithdrawal(uint256 ownershipUnits, uint256 minRawShares) external returns (uint256 requestId);

    /// @notice Returns a pending request's shares to its owner's active position at the current pool price.
    function cancelWithdrawal(uint256 requestId, uint256 minOwnershipUnits) external returns (uint256 ownershipUnits);

    /// @notice Anyone may execute a matured request; its full wstHYPE payout goes to the stored owner.
    function executeWithdrawal(uint256 requestId, uint256 minWstHypeAmount) external returns (uint256 amountWstHype);

    /// @notice Funds a reward stream after the first successful deposit has established the permanent seed.
    function fundRewards(uint256 minNewRawShares) external payable;

    /// @notice Permissionlessly checkpoints rewards and surplus after the first successful deposit.
    function checkpointRewards() external;

    /// @notice Manager or default-admin only; recover unrelated ERC20 tokens, including while paused.
    /// @dev Native HYPE, configured stHYPE and wstHYPE cannot be rescued. Does not checkpoint rewards.
    function rescueTokens(address token, address recipient, uint256 amount) external;

    /// @notice Manager or default-admin only; pauses or resumes all four user asset operations together.
    /// @dev Intended for security incidents. Existing withdrawal requests and maturity timestamps are unchanged.
    function setPaused(bool isPaused) external;

    /// @notice Default-admin only; applies to new requests, preserving existing request maturity.
    function setCooldown(uint64 cooldown) external;

    /// @notice Default-admin only; applies to new funded streams, preserving the current schedule.
    function setRewardDuration(uint64 rewardDuration) external;
}
