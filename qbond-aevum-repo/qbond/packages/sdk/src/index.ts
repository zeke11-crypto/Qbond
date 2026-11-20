import {
  createPublicClient,
  http,
  keccak256,
  parseUnits,
  formatUnits,
  toHex,
  type Address,
  type Hash,
  type PublicClient,
  type WalletClient
} from "viem";
import {
  qdayAevum,
  TUSD8_ADDRESS,
  TUSD8_DECIMALS,
  getExplorerTxUrl,
  getExplorerAddressUrl
} from "./chain.js";
import { ERC20_ABI, IDENTITY_REGISTRY_ABI, QBOND_ESCROW_ABI } from "./abi.js";

export {
  qdayAevum,
  TUSD8_ADDRESS,
  TUSD8_DECIMALS,
  getExplorerTxUrl,
  getExplorerAddressUrl,
  ERC20_ABI,
  IDENTITY_REGISTRY_ABI,
  QBOND_ESCROW_ABI
};

export interface QBondConfig {
  escrowAddress: Address;
  identityRegistryAddress: Address;
  tusd8Address?: Address;
  rpcUrl?: string;
}

export class QBondClient {
  public readonly publicClient: PublicClient;
  public readonly escrowAddress: Address;
  public readonly identityRegistryAddress: Address;
  public readonly tusd8Address: Address;

  constructor(config: QBondConfig) {
    this.escrowAddress = config.escrowAddress;
    this.identityRegistryAddress = config.identityRegistryAddress;
    this.tusd8Address = config.tusd8Address ?? TUSD8_ADDRESS;
    this.publicClient = createPublicClient({
      chain: qdayAevum,
      transport: http(config.rpcUrl ?? qdayAevum.rpcUrls.default.http[0])
    });
  }

  static hashPayload(input: string): Hash {
    return keccak256(toHex(input));
  }

  static parseTUSD8(amount: string | number): bigint {
    return parseUnits(String(amount), TUSD8_DECIMALS);
  }

  static formatTUSD8(amount: bigint): string {
    return formatUnits(amount, TUSD8_DECIMALS);
  }

  async getBalances(account: Address): Promise<{ tqday: bigint; tusd8: bigint }> {
    const [tqday, tusd8] = await Promise.all([
      this.publicClient.getBalance({ address: account }),
      this.publicClient.readContract({
        address: this.tusd8Address,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [account]
      })
    ]);
    return { tqday, tusd8 };
  }

  async approveTUSD8(walletClient: WalletClient, amount: bigint): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.tusd8Address,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [this.escrowAddress, amount]
    });
  }

  async registerAgent(walletClient: WalletClient, agentURI: string): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.identityRegistryAddress,
      abi: IDENTITY_REGISTRY_ABI,
      functionName: "register",
      args: [agentURI]
    });
  }

  async setSessionPolicy(
    walletClient: WalletClient,
    sessionKey: Address,
    maxPerBond: bigint,
    dailyCap: bigint,
    expiresAt: bigint
  ): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.escrowAddress,
      abi: QBOND_ESCROW_ABI,
      functionName: "setSessionPolicy",
      args: [sessionKey, maxPerBond, dailyCap, expiresAt]
    });
  }

  async revokeSession(walletClient: WalletClient, sessionKey: Address): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.escrowAddress,
      abi: QBOND_ESCROW_ABI,
      functionName: "revokeSession",
      args: [sessionKey]
    });
  }

  async createBondWithSession(
    walletClient: WalletClient,
    params: {
      client: Address;
      workerAgentId: bigint;
      verifier?: Address;
      taskHash: Hash;
      amount: bigint;
      deadline: bigint;
    }
  ): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.escrowAddress,
      abi: QBOND_ESCROW_ABI,
      functionName: "createBondWithSession",
      args: [
        params.client,
        params.workerAgentId,
        params.verifier ?? "0x0000000000000000000000000000000000000000",
        params.taskHash,
        params.amount,
        params.deadline
      ]
    });
  }

  async submitMilestone(
    walletClient: WalletClient,
    bondId: bigint,
    receiptHash: Hash,
    receiptURI: string
  ): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.escrowAddress,
      abi: QBOND_ESCROW_ABI,
      functionName: "submitMilestone",
      args: [bondId, receiptHash, receiptURI]
    });
  }

  async approveAndSettle(walletClient: WalletClient, bondId: bigint): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.escrowAddress,
      abi: QBOND_ESCROW_ABI,
      functionName: "approveAndSettle",
      args: [bondId]
    });
  }

  async claimTimeoutRefund(walletClient: WalletClient, bondId: bigint): Promise<Hash> {
    if (!walletClient.account) throw new Error("WalletClient has no active account");
    return walletClient.writeContract({
      chain: qdayAevum,
      account: walletClient.account,
      address: this.escrowAddress,
      abi: QBOND_ESCROW_ABI,
      functionName: "claimTimeoutRefund",
      args: [bondId]
    });
  }
}
