// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {QBondEscrow} from "../src/QBondEscrow.sol";
import {QBondIdentityRegistry} from "../src/mocks/QBondIdentityRegistry.sol";

contract MockTUSD8 is ERC20 {
    constructor() ERC20("Test USD8", "tUSD8") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract QBondEscrowTest is Test {
    MockTUSD8 internal tusd8;
    QBondIdentityRegistry internal registry;
    QBondEscrow internal escrow;

    address internal client = makeAddr("client");
    address internal sessionKey = makeAddr("clientAgentSession");
    address internal worker = makeAddr("workerAgent");
    address internal verifier = makeAddr("verifier");
    address internal keeper = makeAddr("keeper");

    uint256 internal workerAgentId;

    uint256 internal constant ONE_USD8 = 1e6;

    function setUp() public {
        tusd8 = new MockTUSD8();
        registry = new QBondIdentityRegistry();
        escrow = new QBondEscrow(address(tusd8), address(registry));

        tusd8.mint(client, 1_000 * ONE_USD8);

        vm.prank(worker);
        workerAgentId = registry.register("ipfs://qbond-worker-agent-v1");

        vm.prank(client);
        tusd8.approve(address(escrow), type(uint256).max);
    }

    function test_DirectBondHappyPath() public {
        bytes32 taskHash = keccak256("audit-contract-v1");
        bytes32 receiptHash = keccak256("audit-report-sha256");
        uint64 deadline = uint64(block.timestamp + 2 hours);

        vm.prank(client);
        uint256 bondId = escrow.createBond(workerAgentId, address(0), taskHash, 25 * ONE_USD8, deadline);

        assertEq(tusd8.balanceOf(address(escrow)), 25 * ONE_USD8);

        vm.prank(worker);
        escrow.submitMilestone(bondId, receiptHash, "ipfs://receipt-report-1");

        vm.prank(client);
        escrow.approveAndSettle(bondId);

        assertEq(tusd8.balanceOf(worker), 25 * ONE_USD8);
        assertEq(tusd8.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.getBond(bondId).status), uint256(QBondEscrow.BondStatus.SETTLED));
    }

    function test_ScopedSessionBondLifecycleAndCapReset() public {
        uint64 expiry = uint64(block.timestamp + 3 days);

        vm.prank(client);
        escrow.setSessionPolicy(sessionKey, 50 * ONE_USD8, 80 * ONE_USD8, expiry);

        // Bond 1: 50 tUSD8 (within per-bond and daily cap)
        vm.prank(sessionKey);
        uint256 bond1 = escrow.createBondWithSession(
            client,
            workerAgentId,
            address(0),
            keccak256("task-1"),
            50 * ONE_USD8,
            uint64(block.timestamp + 1 hours)
        );
        assertEq(escrow.remainingDailyCap(client, sessionKey), 30 * ONE_USD8);

        // Bond 2: 35 tUSD8 should revert ExceedsDailyCap (50 + 35 = 85 > 80)
        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(QBondEscrow.ExceedsDailyCap.selector, 85 * ONE_USD8, 80 * ONE_USD8)
        );
        escrow.createBondWithSession(
            client,
            workerAgentId,
            address(0),
            keccak256("task-2-overspend"),
            35 * ONE_USD8,
            uint64(block.timestamp + 1 hours)
        );

        // Prompt injection attempt: exceeds per-bond cap (60 > 50)
        vm.prank(sessionKey);
        vm.expectRevert(
            abi.encodeWithSelector(QBondEscrow.ExceedsPerBondCap.selector, 60 * ONE_USD8, 50 * ONE_USD8)
        );
        escrow.createBondWithSession(
            client,
            workerAgentId,
            address(0),
            keccak256("prompt-injection-drain"),
            60 * ONE_USD8,
            uint64(block.timestamp + 1 hours)
        );

        // Worker submits and active session key settles bond 1
        vm.prank(worker);
        escrow.submitMilestone(bond1, keccak256("deliverable-1"), "ipfs://deliverable-1");

        vm.prank(sessionKey);
        escrow.approveAndSettle(bond1);
        assertEq(tusd8.balanceOf(worker), 50 * ONE_USD8);

        // Advance 24 hours -> daily budget resets cleanly
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(escrow.remainingDailyCap(client, sessionKey), 80 * ONE_USD8);
    }

    function test_OneClickSessionRevocationBlocksExecution() public {
        vm.startPrank(client);
        escrow.setSessionPolicy(sessionKey, 20 * ONE_USD8, 100 * ONE_USD8, uint64(block.timestamp + 1 days));
        escrow.revokeSession(sessionKey);
        vm.stopPrank();

        assertEq(escrow.remainingDailyCap(client, sessionKey), 0);

        vm.prank(sessionKey);
        vm.expectRevert(QBondEscrow.SessionNotActive.selector);
        escrow.createBondWithSession(
            client,
            workerAgentId,
            address(0),
            keccak256("revoked-attempt"),
            10 * ONE_USD8,
            uint64(block.timestamp + 1 hours)
        );
    }

    function test_SessionExpirationBlocksExecution() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(client);
        escrow.setSessionPolicy(sessionKey, 20 * ONE_USD8, 100 * ONE_USD8, expiry);

        vm.warp(expiry + 1);

        vm.prank(sessionKey);
        vm.expectRevert(QBondEscrow.SessionExpired.selector);
        escrow.createBondWithSession(
            client,
            workerAgentId,
            address(0),
            keccak256("expired-attempt"),
            10 * ONE_USD8,
            uint64(block.timestamp + 2 hours)
        );
    }

    function test_PermissionlessTimeoutRefund() public {
        uint64 deadline = uint64(block.timestamp + 30 minutes);

        vm.prank(client);
        uint256 bondId = escrow.createBond(workerAgentId, address(0), keccak256("timed-task"), 40 * ONE_USD8, deadline);

        // Too early -> revert
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(QBondEscrow.DeadlineNotReached.selector, deadline, block.timestamp)
        );
        escrow.claimTimeoutRefund(bondId);

        // After deadline -> any address (keeper) can refund client
        vm.warp(deadline + 1);
        uint256 balanceBefore = tusd8.balanceOf(client);

        vm.prank(keeper);
        escrow.claimTimeoutRefund(bondId);

        assertEq(tusd8.balanceOf(client), balanceBefore + 40 * ONE_USD8);
        assertEq(uint256(escrow.getBond(bondId).status), uint256(QBondEscrow.BondStatus.REFUNDED));
    }

    function test_CancelBeforeSubmissionAndVerifierRejection() public {
        // Cancel while FUNDED
        vm.prank(client);
        uint256 b1 = escrow.createBond(
            workerAgentId, verifier, keccak256("cancel-task"), 15 * ONE_USD8, uint64(block.timestamp + 1 hours)
        );

        vm.prank(client);
        escrow.cancelBond(b1);
        assertEq(uint256(escrow.getBond(b1).status), uint256(QBondEscrow.BondStatus.CANCELLED));

        // Reject by neutral verifier after submission
        vm.prank(client);
        uint256 b2 = escrow.createBond(
            workerAgentId, verifier, keccak256("verify-task"), 30 * ONE_USD8, uint64(block.timestamp + 1 hours)
        );

        vm.prank(worker);
        escrow.submitMilestone(b2, keccak256("bad-proof"), "ipfs://bad-proof");

        // Client cannot unilaterally reject when verifier is assigned
        vm.prank(client);
        vm.expectRevert(QBondEscrow.UnauthorizedCaller.selector);
        escrow.rejectAndRefund(b2, "client-override");

        // Designated verifier rejects cleanly
        vm.prank(verifier);
        escrow.rejectAndRefund(b2, "PROOF_HASH_MISMATCH");
        assertEq(uint256(escrow.getBond(b2).status), uint256(QBondEscrow.BondStatus.REFUNDED));
    }

    function testFuzz_PerBondCapAlwaysEnforced(uint256 cap, uint256 attempt) public {
        cap = bound(cap, 1, 500 * ONE_USD8);
        attempt = bound(attempt, cap + 1, 900 * ONE_USD8);

        vm.prank(client);
        escrow.setSessionPolicy(sessionKey, cap, 1_000 * ONE_USD8, uint64(block.timestamp + 1 days));

        vm.prank(sessionKey);
        vm.expectRevert(abi.encodeWithSelector(QBondEscrow.ExceedsPerBondCap.selector, attempt, cap));
        escrow.createBondWithSession(
            client,
            workerAgentId,
            address(0),
            keccak256("fuzz-overspend"),
            attempt,
            uint64(block.timestamp + 1 hours)
        );
    }
}
