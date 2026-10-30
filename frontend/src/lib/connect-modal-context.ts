import { createContext, useContext } from "react";

export type ConnectModalContextValue = {
  open: boolean;
  openConnectModal: () => void;
  closeConnectModal: () => void;
};

export const ConnectModalContext = createContext<ConnectModalContextValue | null>(null);

export function useConnectModal(): ConnectModalContextValue {
  const ctx = useContext(ConnectModalContext);
  if (!ctx) {
    throw new Error("useConnectModal must be used within <ConnectModalProvider>");
  }
  return ctx;
}
