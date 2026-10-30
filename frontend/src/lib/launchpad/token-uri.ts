// The pass tokenURI is produced on-chain by DprkPass: a data: URI holding JSON whose `image` is a base64
// SVG. It is still treated as untrusted. The SVG is only ever rendered through <img src>, where scripts,
// event handlers and external loads inside it don't run.

export type PassMetadata = {
  name?: string;
  description?: string;
  /** `data:image/svg+xml;base64,…` only. */
  image?: string;
};

const MAX_URI_CHARS = 512 * 1024;
const JSON_BASE64 = "data:application/json;base64,";
const SVG_DATA_URI = /^data:image\/svg\+xml;base64,[A-Za-z0-9+/]+={0,2}$/;

function decodeBase64Utf8(b64: string): string {
  const binary = atob(b64);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder("utf-8").decode(bytes);
}

function jsonPayload(uri: string): string | undefined {
  if (uri.startsWith(JSON_BASE64)) return decodeBase64Utf8(uri.slice(JSON_BASE64.length));
  const plain = /^data:application\/json(?:;charset=utf-8|;utf8)?,/i.exec(uri);
  if (plain) return decodeURIComponent(uri.slice(plain[0].length));
  return undefined;
}

export function decodePassTokenUri(uri: unknown): PassMetadata | undefined {
  if (typeof uri !== "string" || uri.length > MAX_URI_CHARS) return undefined;
  let parsed: unknown;
  try {
    const json = jsonPayload(uri.trim());
    if (json === undefined) return undefined;
    parsed = JSON.parse(json);
  } catch {
    return undefined;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
  const obj = parsed as Record<string, unknown>;
  const text = (key: string) => {
    const value = Object.prototype.hasOwnProperty.call(obj, key) ? obj[key] : undefined;
    return typeof value === "string" ? value.slice(0, 512) : undefined;
  };
  const image = Object.prototype.hasOwnProperty.call(obj, "image") ? obj.image : undefined;
  return {
    name: text("name"),
    description: text("description"),
    image: typeof image === "string" && SVG_DATA_URI.test(image) ? image : undefined,
  };
}
