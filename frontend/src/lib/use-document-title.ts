import { useEffect } from "react";

const DEFAULT_TITLE = "DPRK.FUN: Lazarus Checker";

/**
 * Sets document.title while the calling component is mounted; `undefined` leaves the title alone (so a
 * parent can defer to a child that knows better). `title` is plain text, so hostile token names are inert.
 */
export function useDocumentTitle(title: string | undefined): void {
  useEffect(() => {
    if (title === undefined) return;
    document.title = title;
    return () => {
      document.title = DEFAULT_TITLE;
    };
  }, [title]);
}
