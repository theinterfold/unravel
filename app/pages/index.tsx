import { Button } from "@aragon/ods";
import { useWallet } from "@/hooks/useWallet";
import Link from "next/link";
import { plugins } from "@/plugins";
import { PUB_CRISP_INFO_URL } from "@/constants";

export default function Home() {
  const { isConnected, connect, isPending } = useWallet();

  const gameHref = `/plugins/${plugins[0]?.id ?? "game"}/#/`;

  return (
    <section className="mint-slab">
      <div className="mx-auto w-full max-w-screen-xl px-6 py-20">
        <div className="serif-hero">
          <div className="rail">
            <span className="num">№ 01</span>
            <span className="vline" />
            <span className="label">
              Say one
              <br />
              thing
            </span>
          </div>
          <h1>
            Campaign in the <span className="ital">open</span>. Vote in{" "}
            <span className="strike">
              traceable
              <svg viewBox="0 0 200 20" preserveAspectRatio="none" aria-hidden="true">
                <path d="M2,16 Q60,4 120,10 T198,6" />
              </svg>
            </span>{" "}
            secret.
          </h1>
        </div>

        <div className="hero-body-grid">
          <div />
          <p className="lede">
            <span className="dropcap">T</span>en players. Each round you argue your case in public, under your own name
            — then cast an encrypted ballot to send someone home. A committee of independent ciphernodes tallies the
            votes with CRISP and returns only the totals. Everyone learns that three votes fell on you. Nobody ever
            learns who cast them.
          </p>
          <ul className="em-list self-center">
            <li>Promises cost nothing</li>
            <li>Re-vote until the window shuts</li>
            <li>Votes cannot be proven</li>
            <li>The dead pick the winner</li>
          </ul>
        </div>

        <div className="mt-14 flex flex-wrap items-center gap-3">
          {!isConnected && (
            <Button size="lg" variant="primary" onClick={() => connect()}>
              {isPending ? "Connecting…" : "Connect wallet"}
            </Button>
          )}
          <Link href={gameHref}>
            <Button size="lg" variant={isConnected ? "primary" : "tertiary"}>
              Enter the game
            </Button>
          </Link>
          <a href={PUB_CRISP_INFO_URL} target="_blank" rel="noreferrer" className="hero-text-link">
            How the secret ballot works →
          </a>
        </div>
      </div>
    </section>
  );
}
