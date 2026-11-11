// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

import {IStakedHypeEscrow} from "./interfaces/IStakedHypeEscrow.sol";
import {
    IStakedHypeEscrowToken,
    IStakedHypeEscrowWrapper,
    IStakedHypeEscrowOverseer
} from "./interfaces/IStakedHypeEscrowDependencies.sol";

/**
 * @title StakedHypeEscrow
 * @notice Locks wstHYPE behind a withdrawal notice period and compounds funded premiums for active balances.
 * @dev Deployed through a TransparentUpgradeableProxy with separate upgrade governance.
 *      The manager or default admin can globally pause user asset operations for security incidents.
 *      Requested shares earn no SHE premium, but retain ordinary stHYPE reward and slashing exposure as wstHYPE.
 */
contract StakedHypeEscrow is
    IStakedHypeEscrow,
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /**
     *
     *  CONSTANTS
     *
     */

    string public constant NAME = "StakedHypeEscrow";
    uint256 public constant VERSION = 1;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");

    uint256 public constant override RAW_SHARES_PER_WSTHYPE_WEI = 1e6;
    uint64 public constant override MAX_COOLDOWN = 180 days;
    uint64 public constant override MAX_REWARD_DURATION = 7 days;

    /// @notice Holds the backed seed permanently; deposits to it and requests from it are forbidden.
    address public constant override SEED_OWNER = address(1);

    /// @notice Units reserved from the first issuance, included in all subsequent pool pricing.
    /// @dev With the assumed 1B nominal stHYPE supply ceiling, one unit is worth at most 1M stHYPE.
    ///      This is an upstream supply assumption, not a supply cap enforced by SHE.
    uint256 public constant override SEED_OWNERSHIP_UNITS = 1000;

    /**
     *
     *  ERC-7201 STORAGE
     *
     */

    /// @custom:storage-location erc7201:stHYPE.storage.StakedHypeEscrow
    struct StakedHypeEscrowStorage {
        Configuration configuration;
        Accounting accounting;
        RewardStream stream;
        bool paused;
        uint256 requestCount;
        mapping(address => uint256) ownershipUnits;
        mapping(uint256 => WithdrawalRequest) requests;
    }

    // keccak256(abi.encode(uint256(keccak256("stHYPE.storage.StakedHypeEscrow")) - 1)) & ~bytes32(uint256(0xff))
    // forge-lint: disable-next-line(screaming-snake-case-const)
    bytes32 private constant StakedHypeEscrowStorageLocation =
        0xecd281f243c16ba7bca6e716285da9e177b38743a79560d95e19c9cd2cf92a00;

    function _getStakedHypeEscrowStorage() private pure returns (StakedHypeEscrowStorage storage escrow) {
        assembly {
            escrow.slot := StakedHypeEscrowStorageLocation
        }
    }

    /**
     *
     *  INITIALIZERS
     *
     */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes protocol references, durations and operational roles.
     * @dev Include this call in proxy deployment. Protocol references have no setters.
     *      The default admin may change durations for future requests and reward streams.
     *      Cooldown must be positive and at most 180 days; reward duration must be positive and at most 7 days.
     * @param params Protocol configuration, initial role holders and default-admin transfer delay.
     */
    function initialize(InitializationParams calldata params) external override initializer {
        Configuration calldata config = params.configuration;
        require(
            config.stHype.code.length != 0 && config.wstHype.code.length != 0 && config.overseer.code.length != 0
                && config.cooldown != 0 && config.cooldown <= MAX_COOLDOWN && config.rewardDuration != 0
                && config.rewardDuration <= MAX_REWARD_DURATION && params.defaultAdmin != address(0)
                && params.manager != address(0) && params.rewardDistributor != address(0),
            StakedHypeEscrow__InvalidConfiguration()
        );
        require(
            IStakedHypeEscrowWrapper(config.wstHype).sthype() == config.stHype
                && IStakedHypeEscrowOverseer(config.overseer).sthype() == config.stHype
                && IStakedHypeEscrowWrapper(config.wstHype).balanceToShareDecimals() == RAW_SHARES_PER_WSTHYPE_WEI,
            StakedHypeEscrow__InvalidConfiguration()
        );

        __AccessControlDefaultAdminRules_init(params.defaultAdminDelay, params.defaultAdmin);
        __ReentrancyGuard_init();
        _grantRole(MANAGER_ROLE, params.manager);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, params.rewardDistributor);
        _getStakedHypeEscrowStorage().configuration = config;

        emit EscrowConfigured(config.stHype, config.wstHype, config.overseer, config.cooldown, config.rewardDuration);
    }

    /**
     *
     *  VIEW FUNCTIONS
     *
     */

    /**
     * @notice Returns protocol addresses and the durations used for new requests and reward streams, in seconds.
     */
    function configuration() external view override returns (Configuration memory) {
        return _getStakedHypeEscrowStorage().configuration;
    }

    /**
     * @notice Returns whether deposits, withdrawal requests, cancellations and executions are paused.
     */
    function paused() external view override returns (bool) {
        return _getStakedHypeEscrowStorage().paused;
    }

    /**
     * @notice Returns whether a nonReentrant SHE operation is in progress.
     * @dev Integrators can check this before relying on SHE views during external callbacks.
     */
    function isLocked() external view override returns (bool) {
        return _reentrancyGuardEntered();
    }

    /**
     * @notice Returns asset accounting with elapsed rewards and surplus shares included.
     * @dev Totals include the permanent seed. Donations and withdrawal leftovers belong to active balances.
     *      With no units outside the seed, they join the undistributed reserve for a future funded stream.
     */
    function totalAccounting() public view override returns (Accounting memory accounting) {
        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        accounting = escrow.accounting;
        uint256 surplusRawShares = _surplusRawShares(escrow);
        if (accounting.totalOwnershipUnits > SEED_OWNERSHIP_UNITS) {
            uint256 pendingRawShares = _scheduledReleaseRawShares(escrow.stream) - escrow.stream.releasedRawShares;
            accounting.activeRawShares += pendingRawShares + surplusRawShares;
            accounting.rewardRawShares -= pendingRawShares;
        } else {
            accounting.rewardRawShares += surplusRawShares;
        }
    }

    /**
     * @notice Returns an owner's active entitlement.
     * @dev SEED_OWNER has a visible entitlement for accounting, but cannot request or withdraw it.
     * @param owner The position owner.
     * @return ownershipUnits Active pool ownership units.
     * @return activeRawShares Current active entitlement in raw stHYPE shares.
     * @return activeWstHype Current active entitlement in wstHYPE base units, rounded down.
     */
    function account(address owner)
        external
        view
        override
        returns (uint256 ownershipUnits, uint256 activeRawShares, uint256 activeWstHype)
    {
        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        Accounting memory accounting = totalAccounting();
        ownershipUnits = escrow.ownershipUnits[owner];
        if (ownershipUnits != 0) {
            activeRawShares = Math.mulDiv(ownershipUnits, accounting.activeRawShares, accounting.totalOwnershipUnits);
        }
        activeWstHype = activeRawShares / RAW_SHARES_PER_WSTHYPE_WEI;
    }

    /**
     * @notice Returns the current reward stream and retained empty-pool emissions.
     * @return stream Schedule with cumulative elapsed release included, whether allocated or retained.
     * @return undistributedRawShares Reward shares available for rescheduling after this stream ends.
     */
    function rewardState() external view override returns (RewardStream memory stream, uint256 undistributedRawShares) {
        stream = _getStakedHypeEscrowStorage().stream;
        stream.releasedRawShares = _scheduledReleaseRawShares(stream);
        undistributedRawShares = totalAccounting().rewardRawShares - (stream.totalRawShares - stream.releasedRawShares);
    }

    /**
     * @notice Returns a withdrawal request, or an empty record for an unknown ID.
     * @param requestId Request ID obtained from WithdrawalRequested events.
     */
    function getWithdrawalRequest(uint256 requestId) external view override returns (WithdrawalRequest memory) {
        return _getStakedHypeEscrowStorage().requests[requestId];
    }

    /**
     * @notice Quotes ownership units and the raw-share charge for entering the active pool.
     * @dev Uses the supplied pool totals without reading escrow state. Initial issuance reserves 1000 units
     *      for SEED_OWNER; the returned units belong to the beneficiary. Deposit additionally checks that
     *      the initial beneficiary's `ownershipUnits` converts to a positive nominal stHYPE balance.
     * @param maxRawShares Maximum shares offered, divisible by RAW_SHARES_PER_WSTHYPE_WEI.
     * @param activeRawShares Active pool shares, including elapsed reward allocations.
     * @param totalOwnershipUnits Active pool ownership-unit supply.
     * @return ownershipUnits Active units to issue, rounded down.
     * @return acceptedRawShares Charge for those units, rounded up to a whole wstHYPE base unit.
     */
    function quoteEntry(uint256 maxRawShares, uint256 activeRawShares, uint256 totalOwnershipUnits)
        public
        pure
        override
        returns (uint256 ownershipUnits, uint256 acceptedRawShares)
    {
        if (totalOwnershipUnits == 0) {
            require(activeRawShares == 0, StakedHypeEscrow__AccountingInvariant());
            if (maxRawShares <= SEED_OWNERSHIP_UNITS) {
                return (0, 0);
            }
            return (maxRawShares - SEED_OWNERSHIP_UNITS, maxRawShares);
        }
        require(activeRawShares != 0, StakedHypeEscrow__AccountingInvariant());

        ownershipUnits = Math.mulDiv(maxRawShares, totalOwnershipUnits, activeRawShares);
        if (ownershipUnits == 0) {
            return (0, 0);
        }

        // Charge only for issued units, with upward rounding confined to one transfer increment.
        acceptedRawShares = Math.mulDiv(ownershipUnits, activeRawShares, totalOwnershipUnits, Math.Rounding.Ceil);
        acceptedRawShares = Math.ceilDiv(acceptedRawShares, RAW_SHARES_PER_WSTHYPE_WEI) * RAW_SHARES_PER_WSTHYPE_WEI;
        require(acceptedRawShares <= maxRawShares, StakedHypeEscrow__AccountingInvariant());
    }

    /**
     *
     *  EXTERNAL FUNCTIONS
     *
     */

    /**
     * @notice Deposits the wstHYPE charge for newly issued ownership units.
     * @dev Unaccepted tokens remain with the payer. Rewards are checkpointed before pricing entry.
     *      The first payer backs a permanent 1000-unit seed. The seed earns its proportional share while
     *      user units remain, and those assets cannot be withdrawn. It is never issued again on refill.
     * @param maxAmountWstHype Maximum wstHYPE base units the payer is willing to deposit.
     * @param beneficiary Owner of the issued user units; cannot be SEED_OWNER.
     * @param minOwnershipUnits Minimum units to issue.
     * @param minAmountWstHypeAccepted Minimum wstHYPE base units to accept.
     * @return ownershipUnits Units issued to the beneficiary.
     * @return acceptedWstHype wstHYPE base units transferred from the payer.
     */
    function deposit(
        uint256 maxAmountWstHype,
        address beneficiary,
        uint256 minOwnershipUnits,
        uint256 minAmountWstHypeAccepted
    ) external override nonReentrant returns (uint256 ownershipUnits, uint256 acceptedWstHype) {
        require(
            beneficiary != address(0) && beneficiary != address(this) && beneficiary != SEED_OWNER,
            StakedHypeEscrow__InvalidAddress()
        );

        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        _requireNotPaused(escrow);
        _checkpointRewards(escrow);
        Accounting storage accounting = escrow.accounting;
        bool seedPool = accounting.totalOwnershipUnits == 0;

        uint256 acceptedRawShares;
        (ownershipUnits, acceptedRawShares) = quoteEntry(
            maxAmountWstHype * RAW_SHARES_PER_WSTHYPE_WEI, accounting.activeRawShares, accounting.totalOwnershipUnits
        );
        acceptedWstHype = acceptedRawShares / RAW_SHARES_PER_WSTHYPE_WEI;
        require(ownershipUnits != 0 && acceptedWstHype != 0, StakedHypeEscrow__InvalidAmount());
        if (seedPool) {
            // The initial position must meet both the nominal request minimum and the wstHYPE transfer quantum.
            require(
                ownershipUnits >= RAW_SHARES_PER_WSTHYPE_WEI
                    && IStakedHypeEscrowToken(escrow.configuration.stHype).sharesToBalance(ownershipUnits) != 0,
                StakedHypeEscrow__InvalidAmount()
            );
        }
        require(
            ownershipUnits >= minOwnershipUnits && acceptedWstHype >= minAmountWstHypeAccepted,
            StakedHypeEscrow__MinimumNotMet()
        );

        uint256 rawSharesBefore = _heldRawShares(escrow);
        IERC20(escrow.configuration.wstHype).safeTransferFrom(msg.sender, address(this), acceptedWstHype);
        require(
            _heldRawShares(escrow) == rawSharesBefore + acceptedRawShares, StakedHypeEscrow__UnexpectedShareChange()
        );

        accounting.activeRawShares += acceptedRawShares;
        if (seedPool) {
            escrow.ownershipUnits[SEED_OWNER] = SEED_OWNERSHIP_UNITS;
            accounting.totalOwnershipUnits = SEED_OWNERSHIP_UNITS;
        }
        accounting.totalOwnershipUnits += ownershipUnits;
        escrow.ownershipUnits[beneficiary] += ownershipUnits;
        _requireBacking(escrow);

        _emitDeposited(escrow, beneficiary, acceptedWstHype, ownershipUnits, seedPool);
    }

    /**
     * @notice Reserves active shares under a new cooldown.
     * @dev The owner can cancel a pending request to rejoin the active pool at its current price.
     *      The current stHYPE value must be positive, and the reserved shares must cover
     *      at least one wstHYPE wei. There is no nominal upper bound on a request.
     * @param ownershipUnits Positive active units to remove.
     * @param minRawShares Minimum raw shares to reserve.
     * @return requestId New request ID, also emitted for off-chain indexing.
     */
    function requestWithdrawal(uint256 ownershipUnits, uint256 minRawShares)
        external
        override
        nonReentrant
        returns (uint256 requestId)
    {
        require(msg.sender != SEED_OWNER, StakedHypeEscrow__InvalidAddress());
        require(ownershipUnits != 0, StakedHypeEscrow__InvalidAmount());

        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        _requireNotPaused(escrow);
        _checkpointRewards(escrow);
        require(ownershipUnits <= escrow.ownershipUnits[msg.sender], StakedHypeEscrow__InsufficientUnits());

        Accounting storage accounting = escrow.accounting;
        uint256 rawShares = Math.mulDiv(ownershipUnits, accounting.activeRawShares, accounting.totalOwnershipUnits);
        require(rawShares >= RAW_SHARES_PER_WSTHYPE_WEI, StakedHypeEscrow__InvalidAmount());
        require(rawShares >= minRawShares, StakedHypeEscrow__MinimumNotMet());

        uint256 amountStHype = IStakedHypeEscrowToken(escrow.configuration.stHype).sharesToBalance(rawShares);
        require(amountStHype != 0, StakedHypeEscrow__InvalidAmount());

        escrow.ownershipUnits[msg.sender] -= ownershipUnits;
        accounting.totalOwnershipUnits -= ownershipUnits;
        accounting.activeRawShares -= rawShares;
        accounting.requestedRawShares += rawShares;
        requestId = ++escrow.requestCount;
        WithdrawalRequest storage withdrawal = escrow.requests[requestId];
        withdrawal.owner = msg.sender;
        withdrawal.rawShares = rawShares;
        withdrawal.requestedAt = block.timestamp.toUint64();
        withdrawal.eligibleAt = (block.timestamp + escrow.configuration.cooldown).toUint64();
        withdrawal.status = RequestStatus.REQUESTED;
        _requireBacking(escrow);

        emit WithdrawalRequested(
            requestId,
            msg.sender,
            ownershipUnits,
            rawShares,
            withdrawal.eligibleAt,
            _accountBalance(escrow, msg.sender),
            accounting
        );
    }

    /**
     * @notice Returns a pending request's shares to its owner's active position.
     * @dev Available before or after maturity while unpaused. Checkpoints rewards before pricing the
     *      returning shares, so they receive no rewards from their requested period. All reserved raw
     *      shares rejoin the active pool; unit issuance rounds down and must be positive. Cancellation
     *      transfers no tokens. A later withdrawal requires a new request and its own cooldown.
     * @param requestId Pending request owned by the caller.
     * @param minOwnershipUnits Minimum active units to receive at the current pool price.
     * @return ownershipUnits Active units issued to the request owner.
     */
    function cancelWithdrawal(uint256 requestId, uint256 minOwnershipUnits)
        external
        override
        nonReentrant
        returns (uint256 ownershipUnits)
    {
        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        _requireNotPaused(escrow);
        WithdrawalRequest storage withdrawal = escrow.requests[requestId];
        require(withdrawal.status == RequestStatus.REQUESTED, StakedHypeEscrow__InvalidRequest());
        require(withdrawal.owner == msg.sender, StakedHypeEscrow__OnlyRequestOwner());

        _checkpointRewards(escrow);
        Accounting storage accounting = escrow.accounting;
        ownershipUnits = Math.mulDiv(withdrawal.rawShares, accounting.totalOwnershipUnits, accounting.activeRawShares);
        require(ownershipUnits != 0, StakedHypeEscrow__InvalidAmount());
        require(ownershipUnits >= minOwnershipUnits, StakedHypeEscrow__MinimumNotMet());

        withdrawal.status = RequestStatus.CANCELLED;
        accounting.requestedRawShares -= withdrawal.rawShares;
        accounting.activeRawShares += withdrawal.rawShares;
        accounting.totalOwnershipUnits += ownershipUnits;
        escrow.ownershipUnits[withdrawal.owner] += ownershipUnits;
        _requireBacking(escrow);

        emit WithdrawalCancelled(
            requestId,
            withdrawal.owner,
            withdrawal.rawShares,
            ownershipUnits,
            _accountBalance(escrow, withdrawal.owner),
            accounting
        );
    }

    /**
     * @notice Transfers a matured request's wstHYPE to its owner.
     * @dev Anyone may execute; the full payout always goes to the stored owner.
     *      Shares outside this request remain protected, including the permanent seed's entitlement.
     *      Raw shares below one wstHYPE wei belong to active balances, or join the reward reserve
     *      when no user units remain outside the seed.
     * @param requestId Matured request to execute on behalf of its owner.
     * @param minWstHypeAmount Minimum wstHYPE base units transferred to the owner.
     * @return amountWstHype wstHYPE base units transferred to the owner.
     */
    function executeWithdrawal(uint256 requestId, uint256 minWstHypeAmount)
        external
        override
        nonReentrant
        returns (uint256 amountWstHype)
    {
        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        _requireNotPaused(escrow);
        WithdrawalRequest storage withdrawal = escrow.requests[requestId];
        require(withdrawal.status == RequestStatus.REQUESTED, StakedHypeEscrow__InvalidRequest());
        require(block.timestamp >= withdrawal.eligibleAt, StakedHypeEscrow__CooldownNotElapsed());

        amountWstHype = withdrawal.rawShares / RAW_SHARES_PER_WSTHYPE_WEI;
        require(amountWstHype != 0, StakedHypeEscrow__InvalidAmount());
        require(amountWstHype >= minWstHypeAmount, StakedHypeEscrow__MinimumNotMet());
        uint256 rawSharesBefore = _heldRawShares(escrow);
        uint256 transferredRawShares = amountWstHype * RAW_SHARES_PER_WSTHYPE_WEI;
        withdrawal.status = RequestStatus.EXECUTED;
        escrow.accounting.requestedRawShares -= withdrawal.rawShares;

        IERC20(escrow.configuration.wstHype).safeTransfer(withdrawal.owner, amountWstHype);

        uint256 rawSharesAfter = _heldRawShares(escrow);
        require(rawSharesAfter == rawSharesBefore - transferredRawShares, StakedHypeEscrow__UnexpectedShareChange());
        _checkpointRewards(escrow);
        _requireBacking(escrow);

        emit WithdrawalExecuted(
            requestId,
            amountWstHype,
            withdrawal.owner,
            withdrawal.rawShares,
            _accountBalance(escrow, withdrawal.owner),
            escrow.accounting
        );
    }

    /**
     * @notice Starts a reward stream from new HYPE funding and retained undistributed shares.
     * @dev Requires a successful first deposit. A running stream cannot be replaced. New HYPE funding must be positive.
     * @param minNewRawShares Minimum shares minted by this call, excluding retained reserve funding.
     */
    function fundRewards(uint256 minNewRawShares)
        external
        payable
        override
        onlyRole(REWARD_DISTRIBUTOR_ROLE)
        nonReentrant
    {
        require(msg.value != 0, StakedHypeEscrow__InvalidAmount());
        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        require(block.timestamp >= escrow.stream.end, StakedHypeEscrow__StreamActive());
        _checkpointRewards(escrow);

        uint256 rawSharesBefore = _heldRawShares(escrow);
        IStakedHypeEscrowOverseer(escrow.configuration.overseer).mint{value: msg.value}(address(this));
        uint256 rawSharesAfter = _heldRawShares(escrow);
        require(rawSharesAfter > rawSharesBefore, StakedHypeEscrow__UnexpectedShareChange());
        uint256 receivedRawShares = rawSharesAfter - rawSharesBefore;
        escrow.accounting.rewardRawShares += receivedRawShares;
        require(receivedRawShares >= minNewRawShares, StakedHypeEscrow__MinimumNotMet());

        uint256 scheduledRawShares = escrow.accounting.rewardRawShares;
        require(scheduledRawShares != 0, StakedHypeEscrow__InvalidAmount());
        uint64 startTime = block.timestamp.toUint64();
        uint64 endTime = (block.timestamp + escrow.configuration.rewardDuration).toUint64();
        escrow.stream =
            RewardStream({totalRawShares: scheduledRawShares, releasedRawShares: 0, start: startTime, end: endTime});
        _requireBacking(escrow);

        emit RewardsFunded(msg.value, receivedRawShares, scheduledRawShares, startTime, endTime, escrow.accounting);
    }

    /**
     * @notice Allocates elapsed emissions and surplus shares to active balances, or retains them with no user units.
     * @dev Permissionless after the first deposit; the internal checkpoint also runs during the first deposit.
     */
    function checkpointRewards() external override nonReentrant {
        StakedHypeEscrowStorage storage escrow = _getStakedHypeEscrowStorage();
        _checkpointRewards(escrow);
        _requireBacking(escrow);
    }

    /**
     * @notice Recovers unrelated ERC20 tokens mistakenly sent to SHE.
     * @dev Callable by the manager or default admin, including while paused. Native HYPE, stHYPE
     *      and wstHYPE are excluded. Does not checkpoint rewards or change escrow accounting.
     * @param token ERC20 token to recover; cannot be the zero address or either configured token.
     * @param recipient Destination of the recovered tokens; cannot be zero or SHE itself.
     * @param amount Positive amount to transfer, in the rescued token's base units.
     */
    function rescueTokens(address token, address recipient, uint256 amount) external override nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            _checkRole(MANAGER_ROLE);
        }
        Configuration storage config = _getStakedHypeEscrowStorage().configuration;
        require(
            token != address(0) && token != config.stHype && token != config.wstHype, StakedHypeEscrow__ProtectedToken()
        );
        require(recipient != address(0) && recipient != address(this), StakedHypeEscrow__InvalidAddress());
        require(amount != 0, StakedHypeEscrow__InvalidAmount());

        IERC20(token).safeTransfer(recipient, amount);

        emit TokensRescued(token, recipient, amount);
    }

    /**
     * @notice Sets the global security pause for deposits, withdrawal requests, cancellations and executions.
     * @dev Callable by the manager or default admin. Intended for security incidents, not routine
     *      withdrawal management. Existing requests and their maturity timestamps remain unchanged.
     * @param isPaused True to pause all four operations, false to resume them.
     */
    function setPaused(bool isPaused) external override nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            _checkRole(MANAGER_ROLE);
        }
        _getStakedHypeEscrowStorage().paused = isPaused;

        emit PausedSet(isPaused);
    }

    /**
     * @notice Sets the cooldown applied when creating new withdrawal requests.
     * @dev Existing requests keep their eligibleAt timestamp. Existing active balances use the new
     *      cooldown when they request withdrawal; no duration is reserved at deposit time.
     * @param cooldown Duration in seconds, from 1 second through 180 days inclusive.
     */
    function setCooldown(uint64 cooldown) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(cooldown != 0 && cooldown <= MAX_COOLDOWN, StakedHypeEscrow__InvalidConfiguration());
        _getStakedHypeEscrowStorage().configuration.cooldown = cooldown;

        emit CooldownSet(cooldown);
    }

    /**
     * @notice Sets the duration applied when funding the next reward stream.
     * @dev Existing streams keep their start, end and release schedule. This does not checkpoint rewards
     *      or allow funding before the current stream ends. Default-admin transfer delay does not delay setters.
     * @param rewardDuration Duration in seconds, from 1 second through 7 days inclusive.
     */
    function setRewardDuration(uint64 rewardDuration) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(rewardDuration != 0 && rewardDuration <= MAX_REWARD_DURATION, StakedHypeEscrow__InvalidConfiguration());
        _getStakedHypeEscrowStorage().configuration.rewardDuration = rewardDuration;

        emit RewardDurationSet(rewardDuration);
    }

    /**
     *
     *  PRIVATE FUNCTIONS
     *
     */

    function _scheduledReleaseRawShares(RewardStream memory stream) private view returns (uint256) {
        if (stream.end == 0 || block.timestamp <= stream.start) {
            return 0;
        }
        uint256 elapsedSeconds = Math.min(block.timestamp, stream.end) - stream.start;
        return Math.mulDiv(stream.totalRawShares, elapsedSeconds, stream.end - stream.start);
    }

    /// @dev Uses checkpointed storage so the position and pool snapshots describe the same instant.
    function _accountBalance(StakedHypeEscrowStorage storage escrow, address owner)
        private
        view
        returns (AccountBalance memory balance)
    {
        balance.ownershipUnits = escrow.ownershipUnits[owner];
        if (balance.ownershipUnits != 0) {
            balance.activeRawShares = Math.mulDiv(
                balance.ownershipUnits, escrow.accounting.activeRawShares, escrow.accounting.totalOwnershipUnits
            );
        }
    }

    function _emitDeposited(
        StakedHypeEscrowStorage storage escrow,
        address beneficiary,
        uint256 acceptedWstHype,
        uint256 ownershipUnits,
        bool seedPool
    ) private {
        if (seedPool) {
            emit SeedLocked(SEED_OWNER, SEED_OWNERSHIP_UNITS, _accountBalance(escrow, SEED_OWNER), escrow.accounting);
        }
        emit Deposited(
            msg.sender,
            beneficiary,
            acceptedWstHype,
            ownershipUnits,
            _accountBalance(escrow, beneficiary),
            escrow.accounting
        );
    }

    function _checkpointRewards(StakedHypeEscrowStorage storage escrow) private {
        uint256 releasedRawShares = _scheduledReleaseRawShares(escrow.stream);
        uint256 newlyReleasedRawShares = releasedRawShares - escrow.stream.releasedRawShares;
        uint256 surplusRawShares = _surplusRawShares(escrow);
        if (newlyReleasedRawShares == 0 && surplusRawShares == 0) {
            return;
        }
        escrow.stream.releasedRawShares = releasedRawShares;
        // The seed remains backed and owns its previous allocations, but cannot consume empty-period rewards.
        // Deposits to SEED_OWNER and its withdrawals are forbidden, so its unit balance is fixed at 1000.
        if (escrow.accounting.totalOwnershipUnits <= SEED_OWNERSHIP_UNITS) {
            escrow.accounting.rewardRawShares += surplusRawShares;

            emit RewardsCheckpointed(0, newlyReleasedRawShares + surplusRawShares, releasedRawShares, escrow.accounting);
        } else {
            escrow.accounting.rewardRawShares -= newlyReleasedRawShares;
            escrow.accounting.activeRawShares += newlyReleasedRawShares + surplusRawShares;

            emit RewardsCheckpointed(newlyReleasedRawShares + surplusRawShares, 0, releasedRawShares, escrow.accounting);
        }
    }

    function _surplusRawShares(StakedHypeEscrowStorage storage escrow) private view returns (uint256) {
        Accounting storage accounting = escrow.accounting;
        uint256 accountedRawShares =
            accounting.activeRawShares + accounting.requestedRawShares + accounting.rewardRawShares;
        uint256 heldRawShares = _heldRawShares(escrow);
        require(heldRawShares >= accountedRawShares, StakedHypeEscrow__AccountingInvariant());
        return heldRawShares - accountedRawShares;
    }

    function _requireNotPaused(StakedHypeEscrowStorage storage escrow) private view {
        require(!escrow.paused, StakedHypeEscrow__Paused());
    }

    function _heldRawShares(StakedHypeEscrowStorage storage escrow) private view returns (uint256) {
        return IStakedHypeEscrowToken(escrow.configuration.stHype).sharesOf(address(this));
    }

    function _requireBacking(StakedHypeEscrowStorage storage escrow) private view {
        Accounting storage accounting = escrow.accounting;
        uint256 seedUnits = escrow.ownershipUnits[SEED_OWNER];
        require(
            accounting.totalOwnershipUnits >= SEED_OWNERSHIP_UNITS && accounting.activeRawShares != 0
                && seedUnits == SEED_OWNERSHIP_UNITS
                && _heldRawShares(escrow)
                    >= accounting.activeRawShares + accounting.requestedRawShares + accounting.rewardRawShares,
            StakedHypeEscrow__AccountingInvariant()
        );
    }
}
