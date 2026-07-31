import Link from "next/link";
import { useWallet } from "@/hooks/useWallet";
import { plugins } from "@/plugins";
import { PUB_CRISP_INFO_URL } from "@/constants";
import { useGame } from "@/plugins/game/hooks/useGame";
import { Stage } from "@/plugins/game/utils/gameTypes";
import { useFeeToken } from "@/plugins/game/hooks/useFeeToken";

/// The front door.
///
/// Same visual language as the game, one notch louder — this is the only surface allowed to sell.
/// The numbers are read from the live game rather than written into the copy: a landing page that
/// claims twelve players while four are seated is the first lie a new player catches you in.
export default function Home() {
  const { isConnected, connect, isPending } = useWallet();
  const { game } = useGame(30_000);
  const feeToken = useFeeToken();

  const gameHref = `/plugins/${plugins[0]?.id ?? "game"}/#/`;

  const seats = game?.config.minPlayers;
  const taken = game?.alive.length;
  const left = seats !== undefined && taken !== undefined ? Math.max(0, seats - taken) : undefined;
  const inLobby = game?.stage === Stage.Lobby;

  return (
    <main className="un">
      <div className="un-wrap">
        <section className="un-hero">
          <div>
            <div className="un-row" style={{ gap: 10, marginBottom: 24 }}>
              {game && (
                <span className="un-live">
                  <span className="un-live-dot" aria-hidden="true" />
                  {inLobby ? "A GAME IS FORMING" : "A GAME IS LIVE"}
                </span>
              )}
              {taken !== undefined && !inLobby && <span className="un-pill">{taken} STILL BREATHING</span>}
              {game && game.jurors.length > 0 && (
                <span className="un-pill">{game.jurors.length} ON THE JURY, SEETHING</span>
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
                  {inLobby ? "Take a seat" : "Enter the game"}
                </Link>
              )}
              <Link href={gameHref} className="un-btn un-btn-ghost" style={{ textDecoration: "none" }}>
                Just watch, coward
              </Link>
              <Link href="/rules" className="un-btn un-btn-ghost" style={{ textDecoration: "none" }}>
                Read the rules
              </Link>

              {/* Real seats, not a scarcity prop. Absent entirely when there is no game to count. */}
              {inLobby && seats !== undefined && taken !== undefined && (
                <span className="un-seats">
                  <span style={{ display: "flex", gap: 4 }} aria-hidden="true">
                    {Array.from({ length: seats }, (_, i) => (
                      <span
                        key={i}
                        className={`un-seat ${i < taken ? "un-seat-taken" : ""} ${i === taken ? "un-seat-next" : ""}`}
                      />
                    ))}
                  </span>
                  <span className="un-label" style={{ letterSpacing: ".12em" }}>
                    {left} {left === 1 ? "seat" : "seats"} left
                  </span>
                </span>
              )}
            </div>

            <div className="un-grid-2 un-grid-2-wide" style={{ gap: 40 }}>
              <p className="un-prose" style={{ fontSize: 18, maxWidth: "none" }}>
                {seats ?? "A handful of"} players, {game?.config.teamCount ?? "four"} tribes, one pot. You campaign in the
                open — permanent, attributable, deeply screenshot-able — and then vote by a secret ballot nobody can
                open. Not the others. Not us. Get voted out and you don&apos;t go home: you join the jury, and the jury
                picks who walks away rich. So do think about whose feelings you are stamping on.
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

        <section className="un-stats">
          <Stat figure={seats?.toString() ?? "—"} note="players, each convinced they're the smartest one here" accent={true} />
          <Stat
            figure={game?.config.teamCount.toString() ?? "—"}
            note="tribes, most of which will betray the rest by Tuesday"
          />
          {/* Omitted rather than shown raw: an unformatted pot is base units, which reads as noise. */}
          <Stat
            figure={feeToken.format(game?.pot) ?? "—"}
            note={`${feeToken.symbol ? `${feeToken.symbol} in the pot` : "in the pot"}, going to exactly one of them`}
          />
          <Stat figure="0" note="people who can see how you voted. Including us. Forever." />
        </section>
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

const Stat = ({ figure, note, accent }: { figure: string; note: string; accent?: boolean }) => (
  <div className={`un-stat ${accent ? "un-stat-accent" : ""}`}>
    <div className="un-stat-figure">{figure}</div>
    <div className="un-stat-note">{note}</div>
  </div>
);
