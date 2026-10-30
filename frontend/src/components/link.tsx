import type { AnchorHTMLAttributes, MouseEvent } from "react";

import { navigate } from "@/lib/router";

/**
 * In-app link: a real `<a href>` (so open-in-new-tab, copy link and crawlers work) that navigates
 * client-side on a plain left click.
 */
export function Link({
  href,
  onClick,
  target,
  ...rest
}: AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) {
  const handleClick = (event: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(event);
    if (
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey ||
      (target && target !== "_self") ||
      !href.startsWith("/") ||
      href.startsWith("//")
    ) {
      return;
    }
    event.preventDefault();
    navigate(href);
  };

  return <a href={href} target={target} onClick={handleClick} {...rest} />;
}
