import { parseAbi } from "viem";

export const ERC20_ABI = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)"
]);

export const IDENTITY_REGISTRY_ABI = parseAbi([
  "function register(string agentURI) returns (uint256 agentId)",
  "function setAgentURI(uint256 agentId, string newURI)",
  "function ownerOf(uint256 agentId) view returns (address)",
  "function tokenURI(uint256 agentId) view returns (string)",
  "function nextAgentId() view returns (uint256)",
  "event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI)"
]);

export const QBOND_ESCROW_ABI = parseAbi([
  "function tUSD8() view returns (address)",
  "function identityRegistry() view returns (address)",
  "function nextBondId() view returns (uint256)",
  "function remainingDailyCap(address client, address sessionKey) view returns (uint256)",
  "function setSessionPolicy(address sessionKey, uint256 maxPerBond, uint256 dailyCap, uint64 expiresAt)",
  "function revokeSession(address sessionKey)",
  "function createBond(uint256 workerAgentId, address verifier, bytes32 taskHash, uint256 amount, uint64 deadline) returns (uint256)",
  "function createBondWithSession(address client, uint256 workerAgentId, address verifier, bytes32 taskHash, uint256 amount, uint64 deadline) returns (uint256)",
  "function submitMilestone(uint256 bondId, bytes32 receiptHash, string receiptURI)",
  "function approveAndSettle(uint256 bondId)",
  "function cancelBond(uint256 bondId)",
  "function claimTimeoutRefund(uint256 bondId)",
  "function rejectAndRefund(uint256 bondId, string reason)",
  "function bonds(uint256 bondId) view returns (uint256 id, address client, address initiator, uint256 workerAgentId, address workerPayout, address verifier, uint256 amount, bytes32 taskHash, bytes32 receiptHash, string receiptURI, uint64 createdAt, uint64 deadline, uint8 status)",
  "function policies(address client, address sessionKey) view returns (uint256 maxPerBond, uint256 dailyCap, uint256 dailySpent, uint64 windowStart, uint64 expiresAt, bool active)",
  "error ZeroAddress()",
  "error InvalidAmount()",
  "error InvalidDeadline()",
  "error InvalidPolicyParams()",
  "error SessionNotActive()",
  "error SessionExpired()",
  "error ExceedsPerBondCap(uint256 requested, uint256 maxPerBond)",
  "error ExceedsDailyCap(uint256 projected, uint256 dailyCap)",
  "error InvalidWorkerAgent()",
  "error UnauthorizedCaller()",
  "error DeadlinePassed()",
  "error DeadlineNotReached(uint64 deadline, uint256 currentTime)",
  "error EmptyReceiptHash()"
]);
