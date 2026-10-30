import { useConnectionEffect } from "wagmi";

import { writeMockWalletFlag } from "@/lib/launchpad/config";

/**
 * Rendered only in VITE_E2E_MOCK_WALLET builds. Persists the mock wallet's connection across reloads and
 * makes it obvious that transactions are signed by anvil's well-known dev key.
 */
export function E2EWalletBadge() {
  useConnectionEffect({
    onConnect: ({ connector }) => {
      if (connector.type === "mock") writeMockWalletFlag(true);
    },
    onDisconnect: () => writeMockWalletFlag(false),
  });

  return (
    <div
      data-testid="e2e-mock-wallet-badge"
      className="pointer-events-none fixed bottom-2 left-2 z-50 rounded-md bg-amber-400 px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-wider text-black shadow"
    >
      E2E mock wallet · anvil #0
    </div>
  );
}
