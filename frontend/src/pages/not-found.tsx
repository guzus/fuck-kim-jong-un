import { useDocumentTitle } from "@/lib/use-document-title";
import { Link } from "@/components/link";
import { SiteNav } from "@/components/site-nav";
import { buttonVariants } from "@/components/ui/button";
import { routes } from "@/lib/router";

export function NotFoundPage() {
  useDocumentTitle("Not found · DPRK.FUN");
  return (
    <main className="min-h-svh w-full bg-background text-foreground">
      <div className="mx-auto flex w-full max-w-4xl flex-col gap-8 px-6 py-6 sm:py-10">
        <SiteNav active="checker" />
        <div className="flex flex-col items-start gap-3 py-10">
          <span className="font-mono text-sm text-muted-foreground">404</span>
          <h1 className="font-heading text-4xl font-bold tracking-tight">This page defected.</h1>
          <p className="max-w-md text-muted-foreground">
            Whatever was here crossed the border and isn&apos;t coming back.
          </p>
          <div className="flex gap-2 pt-2">
            <Link href={routes.home} className={buttonVariants({ variant: "outline" })}>
              Lazarus Checker
            </Link>
            <Link href={routes.launchpad} className={buttonVariants()}>
              Launchpad
            </Link>
          </div>
        </div>
      </div>
    </main>
  );
}
