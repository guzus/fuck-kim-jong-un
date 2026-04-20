import type { Config } from "@netlify/functions";
import { createPublicClient, fallback, http, type Address } from "viem";
import { mainnet } from "viem/chains";

const ADDRESS = (process.env.VITE_KIM_JONG_UN_ADDRESS ??
  "0xF9fb0c4652A64C444EB19748935670F18560051A") as Address;

// Serverless-friendly RPCs (Cloudflare's bot challenge on eth.llamarpc.com
// bans Netlify Functions egress IPs). Override with STATS_RPC_URL or
// STATS_RPC_URLS (comma-separated).
const DEFAULT_RPCS = [
  "https://ethereum-rpc.publicnode.com",
  "https://rpc.ankr.com/eth",
  "https://eth.merkle.io",
];

const RPC_URLS = (
  process.env.STATS_RPC_URLS?.split(",").map((s) => s.trim()).filter(Boolean) ??
  (process.env.STATS_RPC_URL ? [process.env.STATS_RPC_URL] : DEFAULT_RPCS)
);

const ABI = [
  {
    type: "function",
    name: "totalVerifiedAddresses",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalPigCalls",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalFuckCalls",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

const client = createPublicClient({
  chain: mainnet,
  transport: fallback(
    RPC_URLS.map((url) => http(url, { batch: { wait: 16 } })),
    { rank: false, retryCount: 1 },
  ),
  batch: { multicall: { wait: 16 } },
});

const contract = { address: ADDRESS, abi: ABI } as const;

export default async (): Promise<Response> => {
  try {
    const [verified, pigs, fucks] = await client.multicall({
      allowFailure: false,
      contracts: [
        { ...contract, functionName: "totalVerifiedAddresses" },
        { ...contract, functionName: "totalPigCalls" },
        { ...contract, functionName: "totalFuckCalls" },
      ],
    });

    const body = {
      totalVerifiedAddresses: verified.toString(),
      totalPigCalls: pigs.toString(),
      totalFuckCalls: fucks.toString(),
      address: ADDRESS,
      chainId: mainnet.id,
      fetchedAt: Date.now(),
    };

    return new Response(JSON.stringify(body), {
      status: 200,
      headers: {
        "content-type": "application/json; charset=utf-8",
        // Browsers always revalidate — client-side react-query handles the cache.
        "cache-control": "public, max-age=0, must-revalidate",
        // Netlify durable CDN: one origin hit per 15s globally, serve stale up to
        // 60s past expiry while revalidating in the background.
        "netlify-cdn-cache-control":
          "public, durable, s-maxage=15, stale-while-revalidate=60",
      },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return new Response(JSON.stringify({ error: message }), {
      status: 502,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "public, max-age=0, must-revalidate",
        "netlify-cdn-cache-control": "public, durable, s-maxage=5",
      },
    });
  }
};

export const config: Config = {
  path: "/api/stats",
};
