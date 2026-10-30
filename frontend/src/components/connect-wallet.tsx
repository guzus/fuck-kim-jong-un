import type { Chain } from "viem";
import { useDisconnect, useConnection, useSwitchChain } from "wagmi";
import { mainnet } from "wagmi/chains";

import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useConnectModal } from "@/lib/connect-modal-context";

function shortenAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

/**
 * Connect / wrong-network / disconnect control. `targetChain` is the chain the current page writes to:
 * Ethereum mainnet for the Lazarus Checker (the default), the launchpad chain under /launchpad.
 */
export function ConnectWallet({
  targetChain = mainnet,
  targetLabel = "Mainnet",
}: {
  targetChain?: Chain;
  targetLabel?: string;
}) {
  // `chainId` from the connection is the wallet's real chain, even one the config doesn't know.
  const { address, status, chainId } = useConnection();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const { openConnectModal } = useConnectModal();

  if (status === "connected" && address) {
    const wrongChain = chainId !== targetChain.id;
    return (
      <div className="flex items-center gap-2 flex-wrap justify-end">
        {wrongChain ? (
          <Button
            variant="destructive"
            size="sm"
            disabled={isSwitching}
            onClick={() => switchChain({ chainId: targetChain.id })}
          >
            {isSwitching ? "Switching…" : `Switch to ${targetLabel}`}
          </Button>
        ) : (
          <Badge variant="secondary" className="font-mono">
            {shortenAddress(address)}
          </Badge>
        )}
        <Button variant="outline" size="sm" onClick={() => disconnect()}>
          Disconnect
        </Button>
      </div>
    );
  }

  const busy = status === "connecting" || status === "reconnecting";

  return (
    <Button onClick={openConnectModal} disabled={busy}>
      {busy ? "Connecting…" : "Connect Wallet"}
    </Button>
  );
}
