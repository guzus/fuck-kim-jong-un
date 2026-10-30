import type { Address } from "viem";

// `||`, not `??`: `cp .env.example .env.local` leaves this set to "", which must still mean "use the default".
export const KIM_JONG_UN_ADDRESS = (import.meta.env.VITE_KIM_JONG_UN_ADDRESS?.trim() ||
  "0xF9fb0c4652A64C444EB19748935670F18560051A") as Address;

export const kimJongUnAbi = [
  {
    type: "function",
    name: "pig",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "fuck",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "totalVerifiedAddresses",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalPigCalls",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalFuckCalls",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "isRegardedAsNotNorthKoreanHackerActor",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "pigCalls",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "fuckCalls",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "hasPiggedKimJongUn",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "hasFuckedKimJongUn",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "hasPiggedOrFuckedKimJongUn",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "hasPiggedAndFuckedKimJongUn",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "event",
    name: "CallerRegardedAsNotNorthKoreanHackerActor",
    inputs: [
      { name: "caller", type: "address", indexed: true },
      { name: "action", type: "uint8", indexed: true },
      { name: "firstVerification", type: "bool", indexed: false },
    ],
    anonymous: false,
  },
] as const;
