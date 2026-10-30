import type { ReactNode } from "react";
import { ExternalLink, Globe, Send } from "lucide-react";

import type { SafeLink, TokenMetadata } from "@/lib/launchpad/metadata";

function XIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden fill="currentColor">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
  );
}

function LinkChip({ link, icon }: { link: SafeLink; icon: ReactNode }) {
  // href is a vetted https URL; the visible label is derived from its punycode host, so it can't lie
  // about where the link goes.
  return (
    <a
      href={link.href}
      target="_blank"
      rel="noopener noreferrer nofollow"
      referrerPolicy="no-referrer"
      title={link.href}
      className="inline-flex max-w-full items-center gap-1.5 rounded-md border border-border bg-background px-2 py-1 text-xs text-muted-foreground transition-colors hover:text-foreground"
    >
      {icon}
      <span className="truncate">{link.label}</span>
      <ExternalLink className="size-3 shrink-0" />
    </a>
  );
}

/** Website / X / Telegram links from token metadata. Renders nothing if none survived validation. */
export function MetadataLinks({ metadata }: { metadata: TokenMetadata }) {
  const { website, twitter, telegram } = metadata;
  if (!website && !twitter && !telegram) return null;
  return (
    <div className="flex flex-wrap gap-2">
      {website ? <LinkChip link={website} icon={<Globe className="size-3.5 shrink-0" />} /> : null}
      {twitter ? <LinkChip link={twitter} icon={<XIcon className="size-3 shrink-0" />} /> : null}
      {telegram ? <LinkChip link={telegram} icon={<Send className="size-3.5 shrink-0" />} /> : null}
    </div>
  );
}
