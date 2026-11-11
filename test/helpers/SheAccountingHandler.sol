// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {StakedHypeEscrow} from "../../src/StakedHypeEscrow.sol";
import {StakedHypeEscrowLens} from "../../src/StakedHypeEscrowLens.sol";
import {IStakedHypeEscrow as I} from "../../src/interfaces/IStakedHypeEscrow.sol";
import {Overseer} from "../../src/Overseer.sol";
import {stHYPE} from "../../src/stHYPE.sol";
import {wstHYPE} from "../../src/wstHYPE.sol";

/// @dev Reference ledger for SHE at a constant upstream exchange rate. Slashing, liquidity conditions,
///      callbacks and upgrades have separate integration suites. No expected value comes from a SHE quote/view.
///      The caller must run assertModel after each action; Foundry does this through the invariant.
contract SheAccountingHandler is Test {
    uint256 constant G = 1e6;
    uint256 constant SEED = 1000;
    uint256 constant ROOT = 0xecd281f243c16ba7bca6e716285da9e177b38743a79560d95e19c9cd2cf92a00;
    StakedHypeEscrow public immutable she;
    Overseer immutable overseer;
    stHYPE immutable token;
    wstHYPE immutable wrapper;
    address immutable distributor;
    address immutable manager;
    address immutable admin;
    StakedHypeEscrowLens immutable lens;
    address[3] public owners;
    uint256[3] public ownerUnits;
    uint256[3] public walletShares;
    uint256[3] public walletAllowance;
    uint256[3] public paid;

    uint256 public active;
    uint256 public totalUnits;
    uint256 public seedUnits;
    uint256 public requested;
    uint256 public reserve;
    uint256 public unprocessedDonations;
    uint256 public scheduleTotal;
    uint256 public scheduleProcessed;
    uint256 public scheduleStart;
    uint256 public scheduleEnd;
    uint256 public sharesIn;
    uint256 public sharesTransferred;
    uint256 public nativeMinted;
    uint256 public constant initialBurnCount = 2;
    uint256[13] public actions;
    uint64 public cooldown = 10;
    uint64 public rewardDuration = 100;
    bool public paused;
    uint256 public rejectedDeposits;
    uint256 public rejectedRequests;
    uint256 public rejectedExecutions;
    uint256 public rejectedUnseededFunding;
    uint256 public rejectedUnseededCheckpoints;

    uint256 public cancelledRequests;
    uint256 public rejectedCancellations;

    enum ClaimStatus {
        PENDING,
        EXECUTED,
        CANCELLED
    }

    struct Claim {
        uint256 owner;
        uint256 raw;
        uint64 created;
        uint64 maturity;
        ClaimStatus status;
    }
    Claim[] public claims;

    constructor(
        StakedHypeEscrow she_,
        Overseer overseer_,
        stHYPE token_,
        wstHYPE wrapper_,
        address distributor_,
        address manager_
    ) {
        she = she_;
        overseer = overseer_;
        token = token_;
        wrapper = wrapper_;
        distributor = distributor_;
        manager = manager_;
        admin = msg.sender; // The fixture deployer is the configured admin; do not read an expected value from SHE.
        lens = new StakedHypeEscrowLens();
        owners = [address(0xAC01), address(0xAC02), address(0xAC03)];
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owners[i]);
            wrapper.approve(address(she), type(uint256).max);
            walletAllowance[i] = type(uint256).max;
        }
    }

    function elapsedEmission() public view returns (uint256) {
        if (scheduleEnd == 0 || block.timestamp <= scheduleStart) return 0;
        uint256 elapsed = (block.timestamp < scheduleEnd ? block.timestamp : scheduleEnd) - scheduleStart;
        return scheduleTotal * elapsed / (scheduleEnd - scheduleStart);
    }

    function checkpointModel() private {
        uint256 cumulative = elapsedEmission();
        uint256 released = cumulative - scheduleProcessed;
        if (totalUnits == seedUnits) {
            reserve += unprocessedDonations;
        } else {
            active += released + unprocessedDonations;
            reserve -= released;
        }
        scheduleProcessed = cumulative;
        unprocessedDonations = 0;
    }

    function deposit(uint256 ownerSeed, uint256 amountSeed) external {
        uint256 payer = ownerSeed % 3;
        uint256 beneficiary = (ownerSeed / 3 + payer) % 3;
        depositFor(payer, beneficiary, bound(amountSeed, 2, 100 ether));
        ++actions[0];
    }

    function depositFor(uint256 payer, uint256 beneficiary, uint256 amount) private {
        if (paused) {
            vm.expectRevert(I.StakedHypeEscrow__Paused.selector);
            vm.prank(owners[payer]);
            she.deposit(amount, owners[beneficiary], 0, 0);
            ++rejectedDeposits;
            return;
        }
        uint256 offered = amount * G;
        uint256 effectiveActive =
            totalUnits == seedUnits ? active : active + elapsedEmission() - scheduleProcessed + unprocessedDonations;
        uint256 units = totalUnits == 0 ? offered - SEED : offered * totalUnits / effectiveActive;
        // Zero-unit offers are outside this successful-action handler; deterministic tests assert their exact revert.
        if (units == 0) return;
        checkpointModel();
        // Solve the entitlement inequality directly for whole wrapped units, independently of quoteEntry's two ceilings.
        uint256 charge = totalUnits == 0 ? amount : (units * active + totalUnits * G - 1) / (totalUnits * G);
        overseer.mint{value: amount}(owners[payer]);
        nativeMinted += amount;
        walletShares[payer] += offered;
        vm.prank(owners[payer]);
        (uint256 actualUnits, uint256 accepted) = she.deposit(amount, owners[beneficiary], units, charge);
        assertEq(actualUnits, units);
        assertEq(accepted, charge);
        ownerUnits[beneficiary] += units;
        if (totalUnits == 0) {
            seedUnits = SEED;
            totalUnits = SEED;
        }
        totalUnits += units;
        active += charge * G;
        sharesIn += charge * G;
        walletShares[payer] -= charge * G;
        walletAllowance[payer] -= charge;
    }

    function fund(uint256 amountSeed) external {
        if (block.timestamp < scheduleEnd) return;
        fundAmount(bound(amountSeed, 1, 10 ether));
        ++actions[1];
    }

    function fundAmount(uint256 amount) private {
        if (totalUnits == 0) {
            uint256 payerBefore = distributor.balance;
            vm.expectRevert(I.StakedHypeEscrow__AccountingInvariant.selector);
            vm.prank(distributor);
            she.fundRewards{value: amount}(amount * G);
            assertEq(distributor.balance, payerBefore);
            ++rejectedUnseededFunding;
            assertModel();
            return;
        }
        checkpointModel();
        vm.prank(distributor);
        she.fundRewards{value: amount}(amount * G);
        nativeMinted += amount;
        sharesIn += amount * G;
        reserve += amount * G;
        scheduleTotal = reserve;
        scheduleProcessed = 0;
        scheduleStart = block.timestamp;
        scheduleEnd = block.timestamp + rewardDuration;
    }

    function donate(uint256 amountSeed) external {
        donateAmount(bound(amountSeed, 1, 10 ether));
        ++actions[2];
    }

    function donateAmount(uint256 amount) private {
        overseer.mint{value: amount}(address(this));
        nativeMinted += amount;
        assertTrue(wrapper.transfer(address(she), amount));
        sharesIn += amount * G;
        unprocessedDonations += amount * G;
    }

    function request(uint256 ownerSeed, uint256 fractionSeed) external {
        uint256 who = ownerSeed % 3;
        if (ownerUnits[who] == 0) return;
        uint256 units = ownerUnits[who] * bound(fractionSeed, 1, 10_000) / 10_000;
        requestUnits(who, units);
        ++actions[3];
    }

    function requestUnits(uint256 who, uint256 units) private {
        // Do not persist a model checkpoint when no transaction is sent.
        uint256 effectiveActive = active + elapsedEmission() - scheduleProcessed + unprocessedDonations;
        if (units == 0 || units * effectiveActive / totalUnits < G) return;
        if (paused) {
            vm.expectRevert(I.StakedHypeEscrow__Paused.selector);
            vm.prank(owners[who]);
            she.requestWithdrawal(units, 0);
            ++rejectedRequests;
            return;
        }
        checkpointModel();
        uint256 raw = units * active / totalUnits;
        uint256 expectedId = claims.length + 1;
        vm.prank(owners[who]);
        uint256 id = she.requestWithdrawal(units, raw);
        assertEq(id, expectedId);
        active -= raw;
        totalUnits -= units;
        ownerUnits[who] -= units;
        requested += raw;
        claims.push(Claim(who, raw, uint64(block.timestamp), uint64(block.timestamp + cooldown), ClaimStatus.PENDING));
    }

    function execute(uint256 claimSeed) external {
        if (paused || claims.length == 0) return;
        uint256 index = claimSeed % claims.length;
        if (claims[index].status != ClaimStatus.PENDING || block.timestamp < claims[index].maturity) return;
        executeClaim(index);
        ++actions[4];
    }

    function executeClaim(uint256 index) private {
        Claim storage claim = claims[index];
        uint256 amount = claim.raw / G;
        vm.prank(owners[(claim.owner + 1) % 3]);
        uint256 transferred = she.executeWithdrawal(index + 1, amount);
        assertEq(transferred, amount);
        claim.status = ClaimStatus.EXECUTED;
        requested -= claim.raw;
        sharesTransferred += amount * G;
        paid[claim.owner] += amount;
        walletShares[claim.owner] += amount * G;
        // Transfers remove whole wstHYPE quanta; withdrawal dust stays in custody.
        unprocessedDonations += claim.raw - amount * G;
        checkpointModel();
    }

    function cancel(uint256 claimSeed) external {
        if (paused || claims.length == 0) return;
        uint256 index = claimSeed % claims.length;
        Claim storage claim = claims[index];
        if (claim.status != ClaimStatus.PENDING) return;
        uint256 effectiveActive =
            totalUnits == seedUnits ? active : active + elapsedEmission() - scheduleProcessed + unprocessedDonations;
        uint256 units = claim.raw * totalUnits / effectiveActive;
        // Deterministic tests cover the exact zero-unit error and its rollback.
        if (units == 0) return;
        checkpointModel();
        vm.prank(owners[claim.owner]);
        assertEq(she.cancelWithdrawal(index + 1, units), units);
        claim.status = ClaimStatus.CANCELLED;
        requested -= claim.raw;
        active += claim.raw;
        totalUnits += units;
        ownerUnits[claim.owner] += units;
        ++cancelledRequests;
        ++actions[11];
    }

    function rejectCancellation(uint256 claimSeed, uint256 callerSeed) external {
        if (claims.length == 0) return;
        uint256 index = claimSeed % claims.length;
        Claim memory claim = claims[index];
        uint256 caller = callerSeed % 3;
        uint256 effectiveActive =
            totalUnits == seedUnits ? active : active + elapsedEmission() - scheduleProcessed + unprocessedDonations;
        uint256 units = claim.raw * totalUnits / effectiveActive;
        bytes4 reason;
        if (paused) reason = I.StakedHypeEscrow__Paused.selector;
        else if (claim.status != ClaimStatus.PENDING) reason = I.StakedHypeEscrow__InvalidRequest.selector;
        else if (caller != claim.owner) reason = I.StakedHypeEscrow__OnlyRequestOwner.selector;
        else if (units == 0) reason = I.StakedHypeEscrow__InvalidAmount.selector;
        else reason = I.StakedHypeEscrow__MinimumNotMet.selector;
        vm.expectRevert(reason);
        vm.prank(owners[caller]);
        she.cancelWithdrawal(index + 1, units + 1);
        ++rejectedCancellations;
        ++actions[12];
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 150));
        ++actions[5];
    }

    function checkpoint() external {
        if (totalUnits == 0) {
            vm.expectRevert(I.StakedHypeEscrow__AccountingInvariant.selector);
            she.checkpointRewards();
            ++rejectedUnseededCheckpoints;
            ++actions[6];
            assertModel();
            return;
        }
        she.checkpointRewards();
        checkpointModel();
        ++actions[6];
    }

    function configure(uint256 cooldownSeed, uint256 durationSeed) external {
        // Endpoints have deterministic integration tests. Short intervals keep mixed histories productive.
        cooldown = uint64(bound(cooldownSeed, 1, 300));
        rewardDuration = uint64(bound(durationSeed, 1, 600));
        vm.prank(admin);
        she.setCooldown(cooldown);
        vm.prank(admin);
        she.setRewardDuration(rewardDuration);
        // No model checkpoint: changing future durations must not persist elapsed rewards or donations.
        ++actions[8];
    }

    function setPaused(bool value) external {
        vm.prank(manager);
        she.setPaused(value);
        paused = value;
        ++actions[9];
    }

    function rejectExecution(uint256 claimSeed, uint256 callerSeed) external {
        if (claims.length == 0) return;
        uint256 index = claimSeed % claims.length;
        Claim memory claim = claims[index];
        uint256 caller = callerSeed % 3;
        bytes4 reason;
        if (paused) reason = I.StakedHypeEscrow__Paused.selector;
        else if (claim.status != ClaimStatus.PENDING) reason = I.StakedHypeEscrow__InvalidRequest.selector;
        else if (block.timestamp < claim.maturity) reason = I.StakedHypeEscrow__CooldownNotElapsed.selector;
        else reason = I.StakedHypeEscrow__MinimumNotMet.selector;
        vm.expectRevert(reason);
        vm.prank(owners[caller]);
        she.executeWithdrawal(index + 1, claim.raw / G + 1);
        // The entire reference ledger stays unchanged; assertModel checks every historical record and wallet.
        ++rejectedExecutions;
        ++actions[10];
    }

    function emptyPool() external {
        emptyPoolInternal();
        ++actions[7];
    }

    function emptyPoolInternal() private {
        if (paused) {
            vm.prank(manager);
            she.setPaused(false);
            paused = false;
        }
        for (uint256 i; i < 3; ++i) {
            if (ownerUnits[i] == 0) continue;
            uint256 effectiveActive = active + elapsedEmission() - scheduleProcessed + unprocessedDonations;
            // Top up any sub-wei active entitlement instead of pretending its invalid request should succeed.
            if (ownerUnits[i] * effectiveActive / totalUnits < G) depositFor(i, i, 1 ether);
            requestUnits(i, ownerUnits[i]);
        }
        uint256 maturity = block.timestamp;
        for (uint256 i; i < claims.length; ++i) {
            if (claims[i].status == ClaimStatus.PENDING && claims[i].maturity > maturity) {
                maturity = claims[i].maturity;
            }
        }
        vm.warp(maturity);
        for (uint256 i; i < claims.length; ++i) {
            if (claims[i].status == ClaimStatus.PENDING) executeClaim(i);
        }
        assertEq(totalUnits, seedUnits);
        assertEq(active == 0, seedUnits == 0);
        assertEq(requested, 0);
    }

    function assertModel() public view {
        assertEq(
            abi.encode(she.configuration()),
            abi.encode(I.Configuration(address(token), address(wrapper), address(overseer), cooldown, rewardDuration))
        );
        assertEq(she.paused(), paused);
        assertEq(she.defaultAdmin(), admin);
        assertTrue(she.hasRole(she.MANAGER_ROLE(), manager));
        assertTrue(she.hasRole(she.REWARD_DISTRIBUTOR_ROLE(), distributor));
        uint256 emission = elapsedEmission();
        uint256 effectiveActive = active;
        uint256 effectiveReserve = reserve;
        if (totalUnits != seedUnits) {
            effectiveActive += emission - scheduleProcessed + unprocessedDonations;
            effectiveReserve -= emission - scheduleProcessed;
        } else {
            effectiveReserve += unprocessedDonations;
        }

        // Inspect persistent buckets directly, so implicit surplus reconciliation cannot hide misattribution.
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 4))), active, "stored active");
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 5))), totalUnits, "stored units");
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 6))), requested, "stored requested");
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 7))), reserve, "stored reserve");
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 8))), scheduleTotal, "stored scheduled shares");
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 9))), scheduleProcessed, "stored processed emissions");
        assertEq(uint256(vm.load(address(she), bytes32(ROOT + 12))), claims.length, "request count");
        I.Accounting memory a = she.totalAccounting();
        assertEq(a.activeRawShares, effectiveActive);
        assertEq(a.totalOwnershipUnits, totalUnits);
        assertEq(a.requestedRawShares, requested);
        assertEq(a.rewardRawShares, effectiveReserve);
        (I.RewardStream memory stream, uint256 retained) = she.rewardState();
        assertEq(stream.start, scheduleStart);
        assertEq(stream.end, scheduleEnd);
        assertEq(stream.totalRawShares, scheduleTotal);
        assertEq(stream.releasedRawShares, emission);
        assertEq(retained, effectiveReserve - (scheduleTotal - emission));
        uint256 summedUnits;
        uint256 summedEntitlements;
        uint256 summedPending;
        for (uint256 i; i < 3; ++i) {
            (uint256 units, uint256 raw, uint256 wrapped) = she.account(owners[i]);
            uint256 expected = totalUnits == 0 ? 0 : ownerUnits[i] * effectiveActive / totalUnits;
            assertEq(units, ownerUnits[i]);
            assertEq(raw, expected);
            assertEq(wrapped, expected / G);
            assertEq(lens.previewRequestWithdrawal(she, owners[i], ownerUnits[i]), expected);
            summedUnits += units;
            summedEntitlements += expected;
            assertEq(token.sharesOf(owners[i]), walletShares[i]);
            assertEq(owners[i].balance, 0);
            assertEq(wrapper.allowance(owners[i], address(she)), walletAllowance[i]);
        }
        for (uint256 i; i < claims.length; ++i) {
            Claim memory c = claims[i];
            I.WithdrawalRequest memory actual = she.getWithdrawalRequest(i + 1);
            assertEq(actual.owner, owners[c.owner]);
            assertEq(actual.rawShares, c.raw);
            assertEq(actual.requestedAt, c.created);
            assertEq(actual.eligibleAt, c.maturity);
            assertEq(uint256(actual.status), uint256(c.status) + 1);
            if (c.status == ClaimStatus.PENDING) {
                summedPending += c.raw;
            }
            assertExecutionPreview(i, c);
            uint256 cancellationUnits = c.status == ClaimStatus.PENDING ? c.raw * totalUnits / effectiveActive : 0;
            assertEq(lens.previewCancelWithdrawal(she, i + 1), cancellationUnits);
        }
        (uint256 lockedUnits, uint256 lockedRaw, uint256 lockedWrapped) = she.account(address(1));
        uint256 seedEntitlement = totalUnits == 0 ? 0 : seedUnits * effectiveActive / totalUnits;
        assertEq(lockedUnits, seedUnits);
        assertEq(lockedRaw, seedEntitlement);
        assertEq(lockedWrapped, seedEntitlement / G);
        summedEntitlements += seedEntitlement;
        assertEq(summedUnits + seedUnits, totalUnits);
        assertEq(summedPending, requested);
        assertLe(summedEntitlements, effectiveActive);
        assertLt(effectiveActive - summedEntitlements, 4);
        assertEq(active == 0, totalUnits == 0);
        assertEq(token.sharesOf(address(she)), sharesIn - sharesTransferred, "independent custody ledger");
        assertEq(active + requested + reserve + unprocessedDonations, sharesIn - sharesTransferred);
        assertEq(token.totalSupply(), 0.02 ether + nativeMinted);
        assertEq(token.totalShares(), (0.02 ether + nativeMinted) * G);
        assertEq(address(overseer).balance, 0.02 ether + nativeMinted);
        assertEq(overseer.burnCount(), initialBurnCount);
        assertEq(overseer.totalPendingBurns(), 0);
        assertEq(overseer.getNormalizedRedeemedHype(), 0);
        assertFalse(she.isLocked());
        assertDepositPreview(effectiveActive);
    }

    function assertExecutionPreview(uint256 index, Claim memory claim) private view {
        bool expectedEligible = claim.status == ClaimStatus.PENDING && !paused && block.timestamp >= claim.maturity;
        uint256 expectedAmount = claim.status != ClaimStatus.PENDING ? 0 : claim.raw / G;
        (bool eligible, uint256 amount) = lens.previewExecution(she, index + 1);
        assertEq(eligible, expectedEligible);
        assertEq(amount, expectedAmount);
    }

    function assertDepositPreview(uint256 effectiveActive) private view {
        uint256 offered = 2 ether;
        uint256 expectedUnits = totalUnits == 0 ? offered * G - SEED : offered * G * totalUnits / effectiveActive;
        uint256 expectedCharge =
            totalUnits == 0 ? offered : (expectedUnits * effectiveActive + totalUnits * G - 1) / (totalUnits * G);
        (uint256 units, uint256 charge, uint256 unspent) = lens.previewDeposit(she, offered);
        assertEq(units, expectedUnits);
        assertEq(charge, expectedCharge);
        assertEq(unspent, offered - expectedCharge);
    }
}
