import { defineChain } from "viem";

export const TUSD8_ADDRESS = "0x456569838f1d43009A91ebA4263147Afd7233483" as const;
export const TUSD8_DECIMALS = 6;
export const AEVUM_EXPLORER_URL = "https://explorer-test.qday.info" as const;

export const qdayAevum = defineChain({
  id: 44005,
  name: "QDay Aevum Testnet",
  nativeCurrency: {
    name: "Test QDAY",
    symbol: "tQDAY",
    decimals: 18
  },
  rpcUrls: {
    default: {
      http: ["https://rpc-test.qday.info"],
      webSocket: ["wss://rpc-test.qday.info"]
    }
  },
  blockExplorers: {
    default: {
      name: "QDay Aevum Explorer",
      url: AEVUM_EXPLORER_URL
    }
  },
  testnet: true
});

export function getExplorerTxUrl(hash: `0x${string}`): string {
  return `${AEVUM_EXPLORER_URL}/tx/${hash}`;
}

export function getExplorerAddressUrl(address: `0x${string}`): string {
  return `${AEVUM_EXPLORER_URL}/address/${address}`;
}
