// Token metadata is attacker-controlled: anyone with a pass writes it, the contract only checks its
// length, and it is rendered to every visitor. Rules enforced here:
// - parse defensively: anything that isn't a small JSON object yields no metadata;
// - only known string fields are read, everything else is ignored;
// - links must be https: (ipfs: is rewritten to an https gateway), with no embedded credentials;
// - the X/Telegram icons only link to x.com/twitter.com and t.me/telegram.me respectively;
// - text is stripped of bidi overrides, invisible characters and combining-mark pile-ups, then capped.
// Rendering only ever goes through React text nodes, <img src> and <a href> built from these values.

export const NAME_MAX_BYTES = 64;
export const SYMBOL_MAX_BYTES = 16;
export const METADATA_MAX_BYTES = 1024;

/** Anything far beyond the on-chain cap is not worth parsing. */
const PARSE_LIMIT_CHARS = 8 * 1024;
const URL_MAX_CHARS = 2048;
const IPFS_GATEWAY = "https://ipfs.io/ipfs/";

export type SafeLink = { href: string; label: string };

export type TokenMetadata = {
  description?: string;
  /** https URL safe for <img src>. */
  image?: string;
  website?: SafeLink;
  twitter?: SafeLink;
  telegram?: SafeLink;
};

// C0/C1 controls (except \t \n \r), soft hyphen, zero-width space, bidi marks/overrides/isolates,
// word joiner & invisible operators, BOM, Hangul and braille fillers used for "invisible" names.
// ZWJ/ZWNJ (U+200C/U+200D) stay: emoji sequences and several scripts need them.
const INVISIBLE_OR_BIDI =
  // eslint-disable-next-line no-control-regex -- matching control characters is the point
  /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u00AD\u061C\u115F\u1160\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\u2800\u3164\uFEFF\uFFA0]/g;

function capCodePoints(text: string, max: number): string {
  const chars = Array.from(text);
  return chars.length > max ? `${chars.slice(0, max).join("")}…` : text;
}

/** Multi-line untrusted text (descriptions). */
export function cleanText(raw: unknown, maxChars: number): string | undefined {
  if (typeof raw !== "string") return undefined;
  let text = raw.replace(/\r\n?/g, "\n").replace(INVISIBLE_OR_BIDI, "");
  text = text.replace(/(\p{M}{2})\p{M}+/gu, "$1"); // Zalgo: keep at most two stacked marks
  text = text.replace(/\t/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  return text ? capCodePoints(text, maxChars) : undefined;
}

/** Single-line untrusted text (names, symbols). Falls back when nothing printable is left. */
export function cleanLabel(raw: unknown, maxChars: number, fallback = "Unnamed"): string {
  const text = cleanText(raw, maxChars)?.replace(/\s+/g, " ");
  return text || fallback;
}

function ipfsToGateway(raw: string): string | undefined {
  let rest = raw.slice("ipfs://".length);
  if (rest.toLowerCase().startsWith("ipfs/")) rest = rest.slice("ipfs/".length);
  const slash = rest.indexOf("/");
  const cid = slash === -1 ? rest : rest.slice(0, slash);
  const path = slash === -1 ? "" : rest.slice(slash + 1);
  if (!/^[A-Za-z0-9]{10,128}$/.test(cid)) return undefined;
  if (path && !/^[A-Za-z0-9._~\-/%]{1,512}$/.test(path)) return undefined;
  return `${IPFS_GATEWAY}${cid}${path ? `/${path}` : ""}`;
}

/** Returns a normalized https URL or undefined. ipfs:// is mapped to an https gateway. */
export function toSafeUrl(raw: unknown): URL | undefined {
  if (typeof raw !== "string") return undefined;
  const text = raw.trim();
  if (!text || text.length > URL_MAX_CHARS) return undefined;
  // The URL parser silently drops tabs/newlines ("java\nscript:"); refuse any whitespace or control char.
  // eslint-disable-next-line no-control-regex -- matching control characters is the point
  if (/[\s\u0000-\u001F\u007F-\u009F]/.test(text)) return undefined;
  const candidate = /^ipfs:\/\//i.test(text) ? ipfsToGateway(text) : text;
  if (!candidate) return undefined;
  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:") return undefined;
  // https://pancakeswap.finance@evil.example reads like PancakeSwap but goes to evil.example.
  if (url.username || url.password) return undefined;
  // Needs a dotted public-looking host (no localhost, no bare intranet names).
  if (!url.hostname.includes(".") || url.hostname.endsWith(".")) return undefined;
  return url;
}

function linkLabel(url: URL): string {
  // URL.hostname is punycode for IDNs, so homoglyph domains show up as xn--… rather than lookalikes.
  const host = url.hostname.replace(/^www\./, "");
  const path = url.pathname === "/" ? "" : url.pathname;
  return capCodePoints(`${host}${path}`, 48);
}

export function toSafeWebsite(raw: unknown): SafeLink | undefined {
  const url = toSafeUrl(raw);
  return url ? { href: url.href, label: linkLabel(url) } : undefined;
}

const X_HOSTS = new Set(["x.com", "twitter.com", "www.x.com", "www.twitter.com", "mobile.twitter.com", "mobile.x.com"]);
const TELEGRAM_HOSTS = new Set(["t.me", "telegram.me", "www.t.me", "www.telegram.me"]);

export function toSafeTwitter(raw: unknown): SafeLink | undefined {
  if (typeof raw !== "string") return undefined;
  const handle = /^@?([A-Za-z0-9_]{1,15})$/.exec(raw.trim());
  if (handle) return { href: `https://x.com/${handle[1]}`, label: `@${handle[1]}` };
  const url = toSafeUrl(raw);
  if (!url || !X_HOSTS.has(url.hostname)) return undefined;
  const profile = /^\/([A-Za-z0-9_]{1,15})\/?$/.exec(url.pathname);
  return { href: url.href, label: profile ? `@${profile[1]}` : linkLabel(url) };
}

export function toSafeTelegram(raw: unknown): SafeLink | undefined {
  if (typeof raw !== "string") return undefined;
  const handle = /^@?([A-Za-z0-9_]{5,32})$/.exec(raw.trim());
  if (handle) return { href: `https://t.me/${handle[1]}`, label: `t.me/${handle[1]}` };
  const url = toSafeUrl(raw);
  if (!url || !TELEGRAM_HOSTS.has(url.hostname)) return undefined;
  return { href: url.href, label: linkLabel(url) };
}

function ownString(obj: Record<string, unknown>, key: string): string | undefined {
  if (!Object.prototype.hasOwnProperty.call(obj, key)) return undefined;
  const value = obj[key];
  return typeof value === "string" ? value : undefined;
}

export function parseTokenMetadata(raw: unknown): TokenMetadata {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > PARSE_LIMIT_CHARS) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return {};
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  const obj = parsed as Record<string, unknown>;
  return {
    description: cleanText(ownString(obj, "description"), METADATA_MAX_BYTES),
    image: toSafeUrl(ownString(obj, "image"))?.href,
    website: toSafeWebsite(ownString(obj, "website")),
    twitter: toSafeTwitter(ownString(obj, "twitter")),
    telegram: toSafeTelegram(ownString(obj, "telegram")),
  };
}

export type MetadataInput = {
  description: string;
  image: string;
  website: string;
  twitter: string;
  telegram: string;
};

/**
 * Builds the on-chain metadata string from the create form. Empty fields are omitted; X/Telegram handles
 * are stored as full https URLs so every reader sees a link, not a guess.
 */
export function buildMetadataJson(input: MetadataInput): string {
  const out: Record<string, string> = {};
  const description = input.description.trim();
  if (description) out.description = description;
  const image = input.image.trim();
  if (image) out.image = image;
  const website = input.website.trim();
  if (website) out.website = website;
  const twitter = toSafeTwitter(input.twitter.trim());
  if (input.twitter.trim()) out.twitter = twitter?.href ?? input.twitter.trim();
  const telegram = toSafeTelegram(input.telegram.trim());
  if (input.telegram.trim()) out.telegram = telegram?.href ?? input.telegram.trim();
  return Object.keys(out).length === 0 ? "" : JSON.stringify(out);
}
