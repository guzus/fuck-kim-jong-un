import type { ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { useConnectModal } from "@/lib/connect-modal-context";
import { chainLabel, launchpadConfig } from "@/lib/launchpad/config";
import { useLaunchpadWallet } from "@/lib/launchpad/hooks";
import { cn } from "@/lib/utils";

/**
 * Renders `children` (the real action) only when a wallet is connected on the launchpad chain;
 * otherwise the button that gets the user there: connect, or switch network.
 */
export function WalletGate({ children, className }: { children?: ReactNode; className?: string }) {
  const { connected, wrongChain, isSwitching, switchToLaunchpad } = useLaunchpadWallet();
  const { openConnectModal } = useConnectModal();

  if (!connected) {
    return (
      <Button className={cn("w-full", className)} size="lg" onClick={openConnectModal}>
        Connect wallet
      </Button>
    );
  }
  if (wrongChain) {
    return (
      <Button
        className={cn("w-full", className)}
        size="lg"
        variant="destructive"
        disabled={isSwitching}
        onClick={switchToLaunchpad}
      >
        {isSwitching ? "Switching…" : `Switch to ${chainLabel(launchpadConfig.chain)}`}
      </Button>
    );
  }
  return <>{children}</>;
}
