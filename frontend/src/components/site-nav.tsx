import type { ReactNode } from "react";

import { Link } from "@/components/link";
import { launchpadConfig } from "@/lib/launchpad/config";
import { routes } from "@/lib/router";
import { cn } from "@/lib/utils";

function NavItem({
  href,
  active,
  children,
}: {
  href: string;
  active: boolean;
  children: ReactNode;
}) {
  return (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 text-sm font-medium transition-colors",
        active
          ? "bg-background text-foreground shadow-sm ring-1 ring-foreground/10"
          : "text-muted-foreground hover:text-foreground",
      )}
    >
      {children}
    </Link>
  );
}

/** Primary navigation between the Ethereum checker and the BNB Chain launchpad. */
export function SiteNav({ active }: { active: "checker" | "launchpad" }) {
  return (
    <nav aria-label="Primary" className="flex w-fit items-center gap-1 rounded-lg bg-muted/60 p-1">
      <NavItem href={routes.home} active={active === "checker"}>
        Lazarus Checker
      </NavItem>
      <NavItem href={routes.launchpad} active={active === "launchpad"}>
        Launchpad
        <span className="rounded bg-amber-400/25 px-1 text-[10px] font-semibold uppercase tracking-wide text-amber-800 dark:text-amber-300">
          {launchpadConfig.nativeSymbol}
        </span>
      </NavItem>
    </nav>
  );
}
