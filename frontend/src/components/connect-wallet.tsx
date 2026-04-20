import { useDisconnect, useConnection, useChainId, useSwitchChain } from "wagmi";
import { mainnet } from "wagmi/chains";

import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useConnectModal } from "@/lib/connect-modal";

function shortenAddress(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function ConnectWallet() {
  const { address, status } = useConnection();
  const chainId = useChainId();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const { openConnectModal } = useConnectModal();

  if (status === "connected" && address) {
    const wrongChain = chainId !== mainnet.id;
    return (
      <div className="flex items-center gap-2 flex-wrap justify-end">
        {wrongChain ? (
          <Button
            variant="destructive"
            size="sm"
            disabled={isSwitching}
            onClick={() => switchChain({ chainId: mainnet.id })}
          >
            {isSwitching ? "Switching…" : "Switch to Mainnet"}
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
