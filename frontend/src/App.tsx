import { lazy, Suspense, type ReactNode } from "react";

import { E2EWalletBadge } from "@/components/e2e-wallet-badge";
import { RouteErrorBoundary } from "@/components/route-error-boundary";
import { Toaster } from "@/components/ui/sonner";
import { launchpadConfig } from "@/lib/launchpad/config";
import { matchRoute, usePathname } from "@/lib/router";
import { HomePage } from "@/pages/home";
import { NotFoundPage } from "@/pages/not-found";
import { Providers } from "@/providers";

// The launchpad routes are code-split so `/` doesn't download the launchpad ABIs and UI.
const LaunchpadPage = lazy(() => import("@/pages/launchpad/launchpad-page"));
const CreateTokenPage = lazy(() => import("@/pages/launchpad/create-token-page"));
const TokenPage = lazy(() => import("@/pages/launchpad/token-page"));

function RouteFallback() {
  return (
    <main className="min-h-svh w-full bg-background">
      <div className="mx-auto w-full max-w-5xl px-6 py-10 text-sm text-muted-foreground">Loading…</div>
    </main>
  );
}

function Lazy({ children }: { children: ReactNode }) {
  return <Suspense fallback={<RouteFallback />}>{children}</Suspense>;
}

function Routes() {
  const pathname = usePathname();
  const route = matchRoute(pathname);
  let page: ReactNode;
  switch (route.name) {
    case "home":
      page = <HomePage />;
      break;
    case "launchpad":
      page = (
        <Lazy>
          <LaunchpadPage />
        </Lazy>
      );
      break;
    case "launchpad-create":
      page = (
        <Lazy>
          <CreateTokenPage />
        </Lazy>
      );
      break;
    case "launchpad-token":
      page = (
        <Lazy>
          <TokenPage key={route.address} rawAddress={route.address} />
        </Lazy>
      );
      break;
    default:
      page = <NotFoundPage />;
  }
  // Keyed by path so one broken page (hostile token data, a stale chunk after a deploy) resets on navigation.
  return <RouteErrorBoundary key={pathname}>{page}</RouteErrorBoundary>;
}

function App() {
  return (
    <Providers>
      <Routes />
      <Toaster richColors position="top-right" />
      {import.meta.env.VITE_E2E_MOCK_WALLET === "1" && launchpadConfig.e2eMockWallet ? (
        <E2EWalletBadge />
      ) : null}
    </Providers>
  );
}

export default App;
