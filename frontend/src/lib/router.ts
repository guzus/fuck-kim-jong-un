import { useSyncExternalStore } from "react";

// A pathname router is all four routes need: no params beyond one address, no nested layouts, no
// loaders. Netlify's `/* -> /index.html 200` rewrite already serves the SPA for deep links.

const NAVIGATE_EVENT = "dprk:navigate";

function subscribe(onChange: () => void) {
  window.addEventListener("popstate", onChange);
  window.addEventListener(NAVIGATE_EVENT, onChange);
  return () => {
    window.removeEventListener("popstate", onChange);
    window.removeEventListener(NAVIGATE_EVENT, onChange);
  };
}

export function usePathname(): string {
  return useSyncExternalStore(
    subscribe,
    () => window.location.pathname,
    () => "/",
  );
}

/** Client-side navigation to a same-origin path such as `/launchpad/token/0x…`. */
export function navigate(to: string, options: { replace?: boolean } = {}): void {
  if (!to.startsWith("/") || to.startsWith("//")) {
    throw new Error(`navigate() only accepts same-origin paths, got ${to}`);
  }
  if (options.replace) window.history.replaceState(null, "", to);
  else window.history.pushState(null, "", to);
  window.dispatchEvent(new Event(NAVIGATE_EVENT));
  const hash = to.includes("#") ? to.slice(to.indexOf("#") + 1) : "";
  if (!hash) {
    window.scrollTo(0, 0);
    return;
  }
  // Lazy routes render a moment later, so look for the anchor for up to ~1.5s.
  let tries = 0;
  const seek = () => {
    const target = document.getElementById(decodeURIComponent(hash));
    if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
    else if (tries++ < 30) window.setTimeout(seek, 50);
  };
  seek();
}

export type Route =
  | { name: "home" }
  | { name: "launchpad" }
  | { name: "launchpad-create" }
  | { name: "launchpad-token"; address: string }
  | { name: "not-found" };

export function matchRoute(pathname: string): Route {
  const path = pathname.replace(/\/+$/, "") || "/";
  if (path === "/") return { name: "home" };
  if (path === "/launchpad") return { name: "launchpad" };
  if (path === "/launchpad/create") return { name: "launchpad-create" };
  const token = /^\/launchpad\/token\/([^/]+)$/.exec(path);
  if (token) {
    let address = token[1];
    try {
      address = decodeURIComponent(address);
    } catch {
      // keep the raw segment; the page rejects anything that isn't an address
    }
    return { name: "launchpad-token", address };
  }
  return { name: "not-found" };
}

export const routes = {
  home: "/",
  launchpad: "/launchpad",
  create: "/launchpad/create",
  token: (address: string) => `/launchpad/token/${address}`,
} as const;
