import { ArrowLeft } from "lucide-react";

import { Link } from "@/components/link";
import { CreateTokenForm } from "@/components/launchpad/create-token-form";
import { LaunchpadShell } from "@/components/launchpad/launchpad-shell";
import { routes } from "@/lib/router";
import { useDocumentTitle } from "@/lib/use-document-title";

function Hero() {
  return (
    <section className="flex flex-col gap-2">
      <Link
        href={routes.launchpad}
        className="inline-flex w-fit items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="size-3.5" /> All tokens
      </Link>
      <h1 className="font-heading text-4xl font-bold tracking-tight sm:text-5xl">Launch a token</h1>
      <p className="max-w-2xl text-muted-foreground">
        A fixed-supply token on a bonding curve. Only pass holders can buy until it sells out and
        graduates to PancakeSwap, so the snipers in Pyongyang will have to watch.
      </p>
    </section>
  );
}

export default function CreateTokenPage() {
  useDocumentTitle("Launch a token · DPRK.FUN");
  return (
    <LaunchpadShell hero={<Hero />}>
      <CreateTokenForm />
    </LaunchpadShell>
  );
}
