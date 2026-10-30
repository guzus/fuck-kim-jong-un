import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAccountEffect, useConnect, useConnectors } from "wagmi";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ConnectModalContext } from "@/lib/connect-modal-context";

export function ConnectModalProvider({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState(false);

  const openConnectModal = useCallback(() => setOpen(true), []);
  const closeConnectModal = useCallback(() => setOpen(false), []);

  useAccountEffect({
    onConnect: closeConnectModal,
  });

  const value = useMemo(
    () => ({ open, openConnectModal, closeConnectModal }),
    [open, openConnectModal, closeConnectModal],
  );

  return (
    <ConnectModalContext.Provider value={value}>
      {children}
      <ConnectDialog open={open} onOpenChange={setOpen} />
    </ConnectModalContext.Provider>
  );
}

function ConnectDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const connectors = useConnectors();
  const [pendingId, setPendingId] = useState<string | null>(null);
  const { connect, isPending, error, reset } = useConnect({
    mutation: {
      onSettled: () => setPendingId(null),
    },
  });

  // Clear a stale error when the dialog closes. pendingId needs no reset: it only counts while isPending.
  useEffect(() => {
    if (!open) reset();
  }, [open, reset]);

  const visible = connectors.filter((c) => c.id !== "injected" || connectors.length === 1);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Connect a wallet</DialogTitle>
          <DialogDescription>
            Pick any detected browser wallet. You'll be asked to approve the connection inside
            the wallet UI.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-2">
          {visible.length === 0 ? (
            <EmptyState />
          ) : (
            visible.map((c) => {
              const busy = isPending && pendingId === c.id;
              return (
                <button
                  key={c.uid}
                  type="button"
                  disabled={isPending}
                  onClick={() => {
                    setPendingId(c.id);
                    connect({ connector: c });
                  }}
                  className="group flex items-center gap-3 rounded-lg border border-border bg-background px-3 py-2.5 text-left transition-colors hover:bg-muted disabled:opacity-50 disabled:pointer-events-none"
                >
                  <WalletIcon connector={c} />
                  <span className="flex-1 text-sm font-medium">{c.name}</span>
                  {busy ? (
                    <span className="text-xs text-muted-foreground">Connecting…</span>
                  ) : c.id === "injected" ? (
                    <span className="text-xs text-muted-foreground">Browser</span>
                  ) : null}
                </button>
              );
            })
          )}
        </div>

        {error ? <p className="text-xs text-destructive">{error.message}</p> : null}
      </DialogContent>
    </Dialog>
  );
}

function WalletIcon({
  connector,
}: {
  connector: { icon?: string; name: string; id: string };
}) {
  if (connector.icon) {
    return (
      <img
        src={connector.icon}
        alt=""
        width={28}
        height={28}
        className="size-7 rounded-md object-contain"
      />
    );
  }
  const letter = connector.name.trim().charAt(0).toUpperCase() || "?";
  return (
    <div className="size-7 rounded-md bg-muted flex items-center justify-center text-xs font-semibold">
      {letter}
    </div>
  );
}

function EmptyState() {
  return (
    <div className="flex flex-col gap-2 rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
      <p>No browser wallet detected.</p>
      <p className="text-xs">
        Install{" "}
        <a
          className="underline"
          target="_blank"
          rel="noreferrer"
          href="https://metamask.io/download/"
        >
          MetaMask
        </a>
        ,{" "}
        <a
          className="underline"
          target="_blank"
          rel="noreferrer"
          href="https://rabby.io/"
        >
          Rabby
        </a>
        , or{" "}
        <a
          className="underline"
          target="_blank"
          rel="noreferrer"
          href="https://rainbow.me/download"
        >
          Rainbow
        </a>{" "}
        and reload.
      </p>
    </div>
  );
}
