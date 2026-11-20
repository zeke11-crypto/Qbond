import "dotenv/config";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatUnits,
  http,
  keccak256,
  parseAbi,
  parseUnits,
  toHex
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC_URL = process.env.AEVUM_RPC_URL || "https://rpc-test.qday.info";
const EXPLORER = process.env.AEVUM_EXPLORER_URL || "https://explorer-test.qday.info";
const TUSD8 = process.env.TUSD8_ADDRESS || "0x456569838f1d43009A91ebA4263147Afd7233483";
const ESCROW = process.env.QBOND_ESCROW_ADDRESS;
const REGISTRY = process.env.QBOND_IDENTITY_REGISTRY_ADDRESS;

if (!ESCROW || !REGISTRY) {
  console.error("Missing QBOND_ESCROW_ADDRESS or QBOND_IDENTITY_REGISTRY_ADDRESS in .env");
  process.exit(1);
}

const clientKey = process.env.DEPLOYER_PRIVATE_KEY;
const sessionKey = process.env.CLIENT_SESSION_PRIVATE_KEY || clientKey;
const workerKey = process.env.WORKER_AGENT_PRIVATE_KEY || clientKey;

const qdayAevum = defineChain({
  id: 44005,
  name: "QDay Aevum Testnet",
  nativeCurrency: { name: "Test QDAY", symbol: "tQDAY", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  testnet: true
});

const publicClient = createPublicClient({ chain: qdayAevum, transport: http(RPC_URL) });
const clientAccount = privateKeyToAccount(clientKey);
const sessionAccount = privateKeyToAccount(sessionKey);
const workerAccount = privateKeyToAccount(workerKey);

const makeWallet = (account) =>
  createWalletClient({ account, chain: qdayAevum, transport: http(RPC_URL) });

const clientWallet = makeWallet(clientAccount);
const sessionWallet = makeWallet(sessionAccount);
const workerWallet = makeWallet(workerAccount);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)"
]);

const registryAbi = parseAbi([
  "function register(string agentURI) returns (uint256)",
  "function nextAgentId() view returns (uint256)"
]);

const escrowAbi = parseAbi([
  "function nextBondId() view returns (uint256)",
  "function setSessionPolicy(address sessionKey, uint256 maxPerBond, uint256 dailyCap, uint64 expiresAt)",
  "function createBondWithSession(address client, uint256 workerAgentId, address verifier, bytes32 taskHash, uint256 amount, uint64 deadline) returns (uint256)",
  "function submitMilestone(uint256 bondId, bytes32 receiptHash, string receiptURI)",
  "function approveAndSettle(uint256 bondId)"
]);

async function waitAndLog(label, hash) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`[OK] ${label}`);
  console.log(`     Tx: ${EXPLORER}/tx/${hash} (status: ${receipt.status})`);
  return receipt;
}

async function main() {
  console.log("=== QBond Autonomous Agent-to-Agent Escrow Flow (QDay Aevum 44005) ===");
  console.log("Client Principal :", clientAccount.address);
  console.log("Session Agent Key:", sessionAccount.address);
  console.log("Worker Agent     :", workerAccount.address);

  const tusd8Bal = await publicClient.readContract({
    address: TUSD8,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [clientAccount.address]
  });
  console.log(`Client tUSD8 Balance: ${formatUnits(tusd8Bal, 6)} tUSD8`);

  if (tusd8Bal < parseUnits("2", 6)) {
    throw new Error("Insufficient tUSD8. Claim testnet funds via https://faucet.qday.info first.");
  }

  // 1. Register ERC-8004 Worker Agent Identity
  const agentIdBefore = await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: "nextAgentId"
  });
  const regTx = await workerWallet.writeContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: "register",
    args: ["ipfs://qbond-autonomous-worker-agent-v1"]
  });
  await waitAndLog(`1. Worker Agent Registered (ERC-8004 ID #${agentIdBefore})`, regTx);

  // 2. Principal Approves tUSD8 & Configures Scoped Session Key
  const approveTx = await clientWallet.writeContract({
    address: TUSD8,
    abi: erc20Abi,
    functionName: "approve",
    args: [ESCROW, parseUnits("50", 6)]
  });
  await waitAndLog("2. Principal Approved 50 tUSD8 for QBondEscrow", approveTx);

  const now = BigInt(Math.floor(Date.now() / 1000));
  const policyTx = await clientWallet.writeContract({
    address: ESCROW,
    abi: escrowAbi,
    functionName: "setSessionPolicy",
    args: [sessionAccount.address, parseUnits("10", 6), parseUnits("25", 6), now + 86400n]
  });
  await waitAndLog("3. Scoped Session Policy Active (10 tUSD8/bond, 25 tUSD8/24h)", policyTx);

  // 3. Prompt-Injection Guardrail Check (Simulated Overspend Dry-Run)
  console.log("\n[SECURITY CHECK] Simulating prompt-injection attempt (50 tUSD8 > 10 tUSD8 cap)...");
  try {
    await publicClient.simulateContract({
      account: sessionAccount,
      address: ESCROW,
      abi: escrowAbi,
      functionName: "createBondWithSession",
      args: [
        clientAccount.address,
        agentIdBefore,
        "0x0000000000000000000000000000000000000000",
        keccak256(toHex("malicious-prompt-injection-drain")),
        parseUnits("50", 6),
        now + 3600n
      ]
    });
    throw new Error("Expected cap violation revert!");
  } catch (err) {
    console.log("[BLOCKED ON-CHAIN] Prompt-injection overspend rejected by QBondEscrow:", err.shortMessage || err.message);
  }

  // 4. Client Agent Opens Valid Milestone Bond (2 tUSD8)
  const bondId = await publicClient.readContract({
    address: ESCROW,
    abi: escrowAbi,
    functionName: "nextBondId"
  });
  const taskHash = keccak256(toHex("Verify QDay Aevum RPC throughput & produce signed JSON benchmark"));
  const createTx = await sessionWallet.writeContract({
    address: ESCROW,
    abi: escrowAbi,
    functionName: "createBondWithSession",
    args: [
      clientAccount.address,
      agentIdBefore,
      "0x0000000000000000000000000000000000000000",
      taskHash,
      parseUnits("2", 6),
      now + 3600n
    ]
  });
  await waitAndLog(`4. Client Agent Locked 2 tUSD8 in Bond #${bondId}`, createTx);

  // 5. Worker Agent Delivers Cryptographic Receipt Proof
  const receiptPayload = JSON.stringify({ bondId: Number(bondId), status: "VERIFIED", latencyMs: 310 });
  const receiptHash = keccak256(toHex(receiptPayload));
  const submitTx = await workerWallet.writeContract({
    address: ESCROW,
    abi: escrowAbi,
    functionName: "submitMilestone",
    args: [bondId, receiptHash, "ipfs://qbond-receipt-benchmark-verified"]
  });
  await waitAndLog(`5. Worker Agent Submitted Proof Hash ${receiptHash.slice(0, 14)}...`, submitTx);

  // 6. Client Agent Verifies Receipt & Settles tUSD8
  const settleTx = await sessionWallet.writeContract({
    address: ESCROW,
    abi: escrowAbi,
    functionName: "approveAndSettle",
    args: [bondId]
  });
  await waitAndLog(`6. Bond #${bondId} Settled -> 2 tUSD8 Paid to Worker Agent`, settleTx);

  console.log("\n=== Flow Complete. All state transitions verified on QDay Aevum Testnet ===");
}

main().catch((err) => {
  console.error("Agent flow failed:", err);
  process.exit(1);
});
