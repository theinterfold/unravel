import Link from "next/link";
import { useReadContract } from "wagmi";
import { useWallet } from "@/hooks/useWallet";
import { plugins } from "@/plugins";
import { PUB_CRISP_INFO_URL, PUB_GAME_FACTORY_ADDRESS } from "@/constants";
import { GameFactoryAbi } from "@/plugins/game/artifacts/GameFactory";

/// The front door.
///
/// Same visual language as the game, one notch louder — this is the only surface allowed to sell.
/// It states one number, the lobby count, and reads it from the factory: a landing page that claims
/// twelve players while four are seated is the first lie a new player catches you in. Per-game
/// figures belong to the lobby browser, which is the only place they mean anything.
export default function Home() {
  const { isConnected, connect, isPending } = useWallet();

  const gameHref = `/plugins/${plugins[0]?.id ?? "game"}/#/`;

  // How many lobbies exist, which is the only number this page can honestly state.
  //
  // It used to read one game — seats taken, tribe count, the pot — from whichever address the
  // deployment named. With lobbies there is no such game: every figure was either a stale
  // deployment's or an em-dash, and the ones that did render described one lobby out of many as
  // though it were the whole thing.
  const { data: lobbies } = useReadContract({
    address: PUB_GAME_FACTORY_ADDRESS,
    abi: GameFactoryAbi,
    functionName: "gameCount",
    query: { enabled: !!PUB_GAME_FACTORY_ADDRESS, refetchInterval: 30_000 },
  });

  const count = lobbies === undefined ? undefined : Number(lobbies);

  return (
    <main className="un">
      <div className="un-wrap">
        <section className="un-hero">
          <div>
            <div className="un-row" style={{ gap: 10, marginBottom: 24 }}>
              {!!count && (
                <span className="un-live">
                  <span className="un-live-dot" aria-hidden="true" />
                  {count === 1 ? "ONE GAME IN PLAY" : `${count} GAMES IN PLAY`}
                </span>
              )}
            </div>

            <h1 className="un-hero-head">
              <div>Lie loudly.</div>
              <div className="un-hero-mark">
                Vote <em>invisibly</em>.
              </div>
              <div>Win the whole pot.</div>
            </h1>

            <div className="un-row" style={{ gap: 14, margin: "34px 0 30px" }}>
              {!isConnected ? (
                <button type="button" className="un-btn" onClick={() => connect()}>
                  {isPending ? "Connecting…" : "Take a seat"}
                </button>
              ) : (
                <Link href={gameHref} className="un-btn" style={{ textDecoration: "none" }}>
                  {count ? "Find a lobby" : "Start a lobby"}
                </Link>
              )}
              <Link href={gameHref} className="un-btn un-btn-ghost" style={{ textDecoration: "none" }}>
                Just watch, coward
              </Link>
              <Link href="/rules" className="un-btn un-btn-ghost" style={{ textDecoration: "none" }}>
                Read the rules
              </Link>
            </div>

            <div className="un-grid-2 un-grid-2-wide" style={{ gap: 40 }}>
              <p className="un-prose" style={{ fontSize: 18, maxWidth: "none" }}>
                A handful of players, a few tribes, one pot. You campaign in the open — permanent,
                attributable, deeply screenshot-able — and then vote by a secret ballot nobody can open. Not the others.
                Not us. Get voted out and you don&apos;t go home: you join the jury, and the jury picks who walks away
                rich. So do think about whose feelings you are stamping on.
              </p>
              <div className="un-stack" style={{ gap: 9, alignContent: "start" }}>
                <Rule tone="var(--un-pistachio)" text="SAY ANYTHING, PROVE NOTHING" />
                <Rule tone="var(--un-pistachio)" text="ENCRYPTED BALLOTS, NO TALLIER" />
                <Rule tone="var(--un-condemned)" text="MISS 3 CHECK-INS, DIE OF ADMIN" />
                <Rule tone="var(--un-sage)" text="THE DEAD PICK THE WINNER" />
              </div>
            </div>
          </div>

          {/* The motif: an aggregate that is perfectly legible, made of individuals that are not. */}
          <div className="un-motif">
            <div className="un-motif-dots" aria-hidden="true" />
            <div className="un-motif-orb" aria-hidden="true" />
            <div className="un-motif-body">
              <div className="un-label">The motif</div>
              <p className="un-motif-line">
                You can see the cloud.
                <br />
                You can never see a dot.
              </p>
              <p className="un-note">
                The halftone field is the whole game in one image. It appears wherever privacy is doing work — sealing
                a ballot, waiting on the committee, revealing a tally — and nowhere else, so it never becomes
                wallpaper.
              </p>
            </div>
          </div>
        </section>

        {/* The four-figure strip that stood here read one game's seats, tribes and pot. Every lobby
            has its own, so there was no game for it to describe — only whichever one the browser
            happened to be pointed at, presented as though it were the whole thing. The lobby
            browser shows the real numbers, per lobby, and it is one click away. */}
      </div>

      <div className="un-marquee">
        <div className="un-marquee-track" aria-hidden="true">
          {[...MARQUEE, ...MARQUEE].map((line, i) => (
            <span key={i} style={line === "·" ? { color: "#4f5a52" } : undefined}>
              {line}
            </span>
          ))}
        </div>
      </div>

      <div className="un-wrap" style={{ paddingTop: 26 }}>
        <a href={PUB_CRISP_INFO_URL} target="_blank" rel="noreferrer" className="un-label">
          How the secret ballot works →
        </a>
      </div>
    </main>
  );
}

/// Deliberately the game's own voice rather than quoted players. Invented quotes attributed to
/// nobody would read as real campaign posts from a real round, which is a lie that costs nothing to
/// avoid telling.
const MARQUEE = [
  "Everything you say here is signed, permanent, and admissible.",
  "·",
  "Everything you vote is sealed, and stays sealed.",
  "·",
  "Nobody can prove how you voted. That includes you.",
  "·",
  "The last ballot before the window shuts is the one that counts.",
  "·",
];

const Rule = ({ tone, text }: { tone: string; text: string }) => (
  <div className="un-chip">
    <span className="un-chip-dot" style={{ background: tone }} aria-hidden="true" />
    {text}
  </div>
);
