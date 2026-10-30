import { Component, type ErrorInfo, type ReactNode } from "react";

type State = { error: Error | null };

/**
 * Keeps one broken route (a render bug, hostile on-chain data we failed to anticipate, or a lazy chunk that
 * 404s after a deploy) from blanking the whole app.
 */
export class RouteErrorBoundary extends Component<{ children: ReactNode }, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("[dprk.fun] route crashed", error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;
    const chunkError = /dynamically imported module|Importing a module script failed|Failed to fetch/i.test(
      this.state.error.message,
    );
    return (
      <main className="min-h-svh w-full bg-background text-foreground">
        <div className="mx-auto flex w-full max-w-xl flex-col gap-3 px-6 py-16">
          <h1 className="font-heading text-2xl font-semibold tracking-tight">
            {chunkError ? "A new version of DPRK.FUN is out" : "Something broke on this page"}
          </h1>
          <p className="text-sm text-muted-foreground">
            {chunkError
              ? "Reload to pick it up."
              : "Reload to try again. Your funds are on-chain, not in this tab."}
          </p>
          <div className="flex gap-3 text-sm">
            <button
              type="button"
              className="underline underline-offset-4"
              onClick={() => window.location.reload()}
            >
              Reload
            </button>
            <a className="underline underline-offset-4" href="/">
              Home
            </a>
          </div>
        </div>
      </main>
    );
  }
}
