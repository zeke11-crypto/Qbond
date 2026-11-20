// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC8004IdentityRegistry} from "./interfaces/IERC8004.sol";

/// @title QBondEscrow
/// @notice Agent-to-Agent milestone escrow in tUSD8 (6 decimals) on QDay Aevum Testnet
///         featuring ERC-8004 identity resolution, scoped session keys, rolling spend caps,
///         1-click emergency revocation, and permissionless timeout refunds.
contract QBondEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum BondStatus {
        NONE,
        FUNDED,
        SUBMITTED,
        SETTLED,
        REFUNDED,
        CANCELLED
    }

    struct AgentPolicy {
        uint256 maxPerBond;      // Max tUSD8 (6 decimals) per bond
        uint256 dailyCap;        // Rolling 24h cap in tUSD8 (6 decimals)
        uint256 dailySpent;      // Amount spent in current 24h window
        uint64 windowStart;      // Timestamp of current 24h window start
        uint64 expiresAt;        // Session expiration timestamp
        bool active;             // Instant kill-switch flag
    }

    struct Bond {
        uint256 id;
        address client;          // Funding principal (human or treasury)
        address initiator;       // Client or authorized sessionKey that opened the bond
        uint256 workerAgentId;   // ERC-8004 NFT tokenId of the worker agent
        address workerPayout;    // Resolved ownerOf(workerAgentId)
        address verifier;        // Optional neutral validator/attestor (address(0) = client-verified)
        uint256 amount;          // Locked tUSD8 amount (6 decimals)
        bytes32 taskHash;        // Keccak256 hash of task specification / SLA
        bytes32 receiptHash;     // Keccak256 hash of delivered output proof
        string receiptURI;       // IPFS / HTTPS URI to verifiable output artifact
        uint64 createdAt;
        uint64 deadline;         // Unix timestamp after which timeout refund is unlocked
        BondStatus status;
    }

    IERC20 public immutable tUSD8;
    IERC8004IdentityRegistry public immutable identityRegistry;

    uint256 public nextBondId = 1;

    /// @notice bondId => Bond
    mapping(uint256 => Bond) public bonds;

    /// @notice client => sessionKey => AgentPolicy
    mapping(address => mapping(address => AgentPolicy)) public policies;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event SessionPolicyUpdated(
        address indexed client,
        address indexed sessionKey,
        uint256 maxPerBond,
        uint256 dailyCap,
        uint64 expiresAt
    );
    event SessionRevoked(address indexed client, address indexed sessionKey);

    event BondCreated(
        uint256 indexed bondId,
        address indexed client,
        address indexed initiator,
        uint256 workerAgentId,
        address workerPayout,
        address verifier,
        uint256 amount,
        bytes32 taskHash,
        uint64 deadline
    );
    event MilestoneSubmitted(
        uint256 indexed bondId,
        uint256 indexed workerAgentId,
        bytes32 receiptHash,
        string receiptURI
    );
    event BondSettled(
        uint256 indexed bondId,
        address indexed approver,
        address indexed workerPayout,
        uint256 amount
    );
    event BondCancelled(uint256 indexed bondId, address indexed client, uint256 amount);
    event BondRefunded(
        uint256 indexed bondId,
        address indexed client,
        address indexed caller,
        uint256 amount,
        string reason
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidPolicyParams();
    error SessionNotActive();
    error SessionExpired();
    error ExceedsPerBondCap(uint256 requested, uint256 maxPerBond);
    error ExceedsDailyCap(uint256 projected, uint256 dailyCap);
    error InvalidWorkerAgent();
    error InvalidBondStatus(BondStatus current, BondStatus expected);
    error UnauthorizedCaller();
    error DeadlinePassed();
    error DeadlineNotReached(uint64 deadline, uint256 currentTime);
    error EmptyReceiptHash();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _tUSD8, address _identityRegistry) {
        if (_tUSD8 == address(0) || _identityRegistry == address(0)) {
            revert ZeroAddress();
        }
        tUSD8 = IERC20(_tUSD8);
        identityRegistry = IERC8004IdentityRegistry(_identityRegistry);
    }

    // -------------------------------------------------------------------------
    // View Helpers
    // -------------------------------------------------------------------------

    function getBond(uint256 bondId) external view returns (Bond memory) {
        return bonds[bondId];
    }

    function getPolicy(address client, address sessionKey) external view returns (AgentPolicy memory) {
        return policies[client][sessionKey];
    }

    /// @notice Returns remaining daily spend capacity for a client's session key
    function remainingDailyCap(address client, address sessionKey) external view returns (uint256) {
        AgentPolicy storage policy = policies[client][sessionKey];
        if (!policy.active || block.timestamp > policy.expiresAt) return 0;
        if (block.timestamp >= policy.windowStart + 1 days) {
            return policy.dailyCap;
        }
        return policy.dailyCap > policy.dailySpent ? policy.dailyCap - policy.dailySpent : 0;
    }

    // -------------------------------------------------------------------------
    // Scoped Session Key Management (Safety, Trust & Controls)
    // -------------------------------------------------------------------------

    /// @notice Grant or update a scoped session key for an autonomous client agent
    function setSessionPolicy(
        address sessionKey,
        uint256 maxPerBond,
        uint256 dailyCap,
        uint64 expiresAt
    ) external {
        if (sessionKey == address(0)) revert ZeroAddress();
        if (maxPerBond == 0 || dailyCap < maxPerBond || expiresAt <= block.timestamp) {
            revert InvalidPolicyParams();
        }

        AgentPolicy storage policy = policies[msg.sender][sessionKey];
        policy.maxPerBond = maxPerBond;
        policy.dailyCap = dailyCap;
        policy.expiresAt = expiresAt;
        policy.active = true;
        if (policy.windowStart == 0) {
            policy.windowStart = uint64(block.timestamp);
        }

        emit SessionPolicyUpdated(msg.sender, sessionKey, maxPerBond, dailyCap, expiresAt);
    }

    /// @notice Instant 1-tx emergency kill switch for a compromised or runaway agent key
    function revokeSession(address sessionKey) external {
        policies[msg.sender][sessionKey].active = false;
        emit SessionRevoked(msg.sender, sessionKey);
    }

    // -------------------------------------------------------------------------
    // Escrow Lifecycle
    // -------------------------------------------------------------------------

    /// @notice Client directly creates and funds a milestone bond in tUSD8
    function createBond(
        uint256 workerAgentId,
        address verifier,
        bytes32 taskHash,
        uint256 amount,
        uint64 deadline
    ) external nonReentrant returns (uint256 bondId) {
        return _createBond(msg.sender, msg.sender, workerAgentId, verifier, taskHash, amount, deadline);
    }

    /// @notice Authorized autonomous agent session key creates a bond on behalf of `client`
    ///         subject to strict on-chain per-bond cap, rolling daily cap, and expiry.
    function createBondWithSession(
        address client,
        uint256 workerAgentId,
        address verifier,
        bytes32 taskHash,
        uint256 amount,
        uint64 deadline
    ) external nonReentrant returns (uint256 bondId) {
        _consumeSessionBudget(client, msg.sender, amount);
        return _createBond(client, msg.sender, workerAgentId, verifier, taskHash, amount, deadline);
    }

    /// @notice Worker agent owner submits verifiable deliverable proof before the deadline
    function submitMilestone(
        uint256 bondId,
        bytes32 receiptHash,
        string calldata receiptURI
    ) external {
        Bond storage bond = bonds[bondId];
        if (bond.status != BondStatus.FUNDED) {
            revert InvalidBondStatus(bond.status, BondStatus.FUNDED);
        }
        if (block.timestamp > bond.deadline) revert DeadlinePassed();
        if (receiptHash == bytes32(0)) revert EmptyReceiptHash();

        address currentOwner = _resolveAgentOwner(bond.workerAgentId);
        if (msg.sender != currentOwner) revert UnauthorizedCaller();

        bond.workerPayout = currentOwner;
        bond.receiptHash = receiptHash;
        bond.receiptURI = receiptURI;
        bond.status = BondStatus.SUBMITTED;

        emit MilestoneSubmitted(bondId, bond.workerAgentId, receiptHash, receiptURI);
    }

    /// @notice Release locked tUSD8 to the worker agent after receipt verification.
    ///         Callable by client, an active session key of the client, or designated verifier.
    function approveAndSettle(uint256 bondId) external nonReentrant {
        Bond storage bond = bonds[bondId];
        if (bond.status != BondStatus.SUBMITTED) {
            revert InvalidBondStatus(bond.status, BondStatus.SUBMITTED);
        }

        bool isClient = msg.sender == bond.client;
        bool isVerifier = bond.verifier != address(0) && msg.sender == bond.verifier;
        bool isActiveSession = _isValidSession(bond.client, msg.sender);

        if (!isClient && !isVerifier && !isActiveSession) {
            revert UnauthorizedCaller();
        }

        bond.status = BondStatus.SETTLED;
        tUSD8.safeTransfer(bond.workerPayout, bond.amount);

        emit BondSettled(bondId, msg.sender, bond.workerPayout, bond.amount);
    }

    /// @notice Client can cancel and reclaim tUSD8 immediately if work has not been submitted yet
    function cancelBond(uint256 bondId) external nonReentrant {
        Bond storage bond = bonds[bondId];
        if (bond.status != BondStatus.FUNDED) {
            revert InvalidBondStatus(bond.status, BondStatus.FUNDED);
        }
        if (msg.sender != bond.client) revert UnauthorizedCaller();

        bond.status = BondStatus.CANCELLED;
        tUSD8.safeTransfer(bond.client, bond.amount);

        emit BondCancelled(bondId, bond.client, bond.amount);
    }

    /// @notice Permissionless timeout refund if the worker misses the deadline without submitting
    function claimTimeoutRefund(uint256 bondId) external nonReentrant {
        Bond storage bond = bonds[bondId];
        if (bond.status != BondStatus.FUNDED) {
            revert InvalidBondStatus(bond.status, BondStatus.FUNDED);
        }
        if (block.timestamp <= bond.deadline) {
            revert DeadlineNotReached(bond.deadline, block.timestamp);
        }

        bond.status = BondStatus.REFUNDED;
        tUSD8.safeTransfer(bond.client, bond.amount);

        emit BondRefunded(bondId, bond.client, msg.sender, bond.amount, "DEADLINE_EXPIRED");
    }

    /// @notice Reject a submitted deliverable and refund client.
    ///         If a neutral verifier is assigned, only the verifier can reject;
    ///         otherwise the client can reject with an auditable reason string.
    function rejectAndRefund(uint256 bondId, string calldata reason) external nonReentrant {
        Bond storage bond = bonds[bondId];
        if (bond.status != BondStatus.SUBMITTED) {
            revert InvalidBondStatus(bond.status, BondStatus.SUBMITTED);
        }

        if (bond.verifier != address(0)) {
            if (msg.sender != bond.verifier) revert UnauthorizedCaller();
        } else {
            if (msg.sender != bond.client) revert UnauthorizedCaller();
        }

        bond.status = BondStatus.REFUNDED;
        tUSD8.safeTransfer(bond.client, bond.amount);

        emit BondRefunded(bondId, bond.client, msg.sender, bond.amount, reason);
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    function _createBond(
        address client,
        address initiator,
        uint256 workerAgentId,
        address verifier,
        bytes32 taskHash,
        uint256 amount,
        uint64 deadline
    ) internal returns (uint256 bondId) {
        if (amount == 0) revert InvalidAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        address workerOwner = _resolveAgentOwner(workerAgentId);

        bondId = nextBondId++;
        bonds[bondId] = Bond({
            id: bondId,
            client: client,
            initiator: initiator,
            workerAgentId: workerAgentId,
            workerPayout: workerOwner,
            verifier: verifier,
            amount: amount,
            taskHash: taskHash,
            receiptHash: bytes32(0),
            receiptURI: "",
            createdAt: uint64(block.timestamp),
            deadline: deadline,
            status: BondStatus.FUNDED
        });

        tUSD8.safeTransferFrom(client, address(this), amount);

        emit BondCreated(
            bondId,
            client,
            initiator,
            workerAgentId,
            workerOwner,
            verifier,
            amount,
            taskHash,
            deadline
        );
    }

    function _consumeSessionBudget(address client, address sessionKey, uint256 amount) internal {
        AgentPolicy storage policy = policies[client][sessionKey];
        if (!policy.active) revert SessionNotActive();
        if (block.timestamp > policy.expiresAt) revert SessionExpired();
        if (amount > policy.maxPerBond) {
            revert ExceedsPerBondCap(amount, policy.maxPerBond);
        }

        if (block.timestamp >= policy.windowStart + 1 days) {
            policy.windowStart = uint64(block.timestamp);
            policy.dailySpent = 0;
        }

        uint256 projected = policy.dailySpent + amount;
        if (projected > policy.dailyCap) {
            revert ExceedsDailyCap(projected, policy.dailyCap);
        }

        policy.dailySpent = projected;
    }

    function _isValidSession(address client, address sessionKey) internal view returns (bool) {
        AgentPolicy storage policy = policies[client][sessionKey];
        return policy.active && block.timestamp <= policy.expiresAt;
    }

    function _resolveAgentOwner(uint256 agentId) internal view returns (address owner) {
        try identityRegistry.ownerOf(agentId) returns (address resolved) {
            if (resolved == address(0)) revert InvalidWorkerAgent();
            return resolved;
        } catch {
            revert InvalidWorkerAgent();
        }
    }
}
