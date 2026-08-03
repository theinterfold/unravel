import type { FC, ReactNode } from "react";
import Link from "next/link";
import { plugins } from "@/plugins";
import { useGame } from "@/plugins/game/hooks/useGame";
import { useFeeToken } from "@/plugins/game/hooks/useFeeToken";
import { MAX_TEAM_SIZE } from "@/plugins/game/utils/gameTypes";
import { TRIBES } from "@/plugins/game/utils/tribes";

/// The rules, for the game that is actually deployed.
///
/// Every number here is read from the contract rather than written into the copy. A rules page that
/// disagrees with the game is worse than no rules page: players will believe it, act on it, and be
/// eliminated by the difference. Where the config cannot be read the number is simply absent.
export default function RulesPage() {
  const { game } = useGame(30_000);
  const feeToken = useFeeToken();
  const cfg = game?.config;

  const gameHref = `/plugins/${plugins[0]?.id ?? "game"}/#/`;
  const capacity = cfg ? cfg.teamCount * MAX_TEAM_SIZE : undefined;

  return (
    <main className="un">
      <div className="un-wrap" style={{ paddingTop: 40, maxWidth: 900 }}>
        <div className="un-label">The rules</div>
        <h1 className="un-hero-head" style={{ fontSize: "clamp(38px, 6vw, 64px)", margin: "14px 0 26px" }}>
          How this ends
          <br />
          for everyone but one.
        </h1>

        <p className="un-prose" style={{ fontSize: 18, maxWidth: "none" }}>
          A social survival game. Players split into tribes and share one pot. Every round the group votes somebody
          out. The last two are judged by everyone they eliminated.
        </p>

        <Section title="Getting in">
          <p className="un-prose">
            You take a seat on a tribe. A tribe needs at least{" "}
            <Fact>{cfg ? `${cfg.minMembersPerTeam} ${cfg.minMembersPerTeam === 1 ? "member" : "members"}` : "a minimum"}</Fact>{" "}
            before the game can start, and can hold up to <Fact>{MAX_TEAM_SIZE}</Fact> — the only ceiling, and it comes
            from the proving circuit rather than from taste.
          </p>
          <p className="un-prose">
            Once <Fact>{cfg?.minPlayers ?? "enough"}</Fact> players have joined and every tribe meets its minimum,{" "}
            <em>anyone</em> can start the game. There is no host. Any seat still empty at that moment stays empty for
            the rest of the game{capacity ? `, so a game runs with ${cfg?.minPlayers} to ${capacity} players` : ""}.
          </p>
        </Section>

        <Section title="A round">
          <p className="un-prose">Three phases, on a clock that does not wait for anybody.</p>
          <Phase
            name="Campaign"
            length={cfg ? duration(cfg.campaignDuration) : undefined}
            body="Everyone talks in public. Posts are signed with your address and permanent. Deals, accusations, alliances, promises. This is where the game is actually played."
          />
          <Phase
            name="Ballot"
            length={cfg ? duration(cfg.ballotDuration) : undefined}
            body="You pick a name and seal a vote — 45 to 90 seconds of proving, in your browser. You may change your mind as often as you like; the last ballot before the window shuts is the one that counts."
          />
          <Phase
            name="Tally"
            length={cfg ? duration(cfg.tallyGrace) : undefined}
            body="The counts come back and somebody goes home, as soon as the committee publishes them. Only the totals are ever revealed — never who cast what. The window is a deadline, not a delay: if the committee never delivers, the round can be abandoned once it expires."
          />
          <p className="un-note">
            The sealed ballots appear on chain as they land, and none of them can be read. That list is not turnout: a
            mask makes an entry, and changing your vote makes another without removing the first.
          </p>
        </Section>

        <Section title="The four kinds of round">
          <div style={{ overflowX: "auto" }}>
            <table className="un-rules-table">
              <thead>
                <tr>
                  <th>Round</th>
                  <th>Who votes</th>
                  <th>On what</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>Tribal</td>
                  <td>everyone alive</td>
                  <td>a tribe — the one with the most votes goes to council</td>
                </tr>
                <tr>
                  <td>Council</td>
                  <td>only the condemned tribe</td>
                  <td>which of themselves is eliminated</td>
                </tr>
                <tr>
                  <td>Solo</td>
                  <td>everyone alive</td>
                  <td>a person, once tribes have dissolved</td>
                </tr>
                <tr>
                  <td>Jury</td>
                  <td>the eliminated</td>
                  <td>which finalist wins</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p className="un-prose">
            In a tribal round you are choosing who has to bleed, not who dies. Council is the cruel one: three people
            who are probably allies have to knife one of each other, alone, while the rest of the game watches and
            cannot help.
          </p>
          <p className="un-prose">
            Tribes dissolve once <Fact>{cfg?.mergeAt ?? "few enough"}</Fact> players remain, after which every round is
            a solo vote. Your own tribe is always on the ballot, and in a council round it is the whole ballot — so
            yes, you can vote out your own, and you can vote for yourself.
          </p>
        </Section>

        <Section title="Two ways to die">
          <p className="un-prose">
            <strong>Voted out.</strong> The obvious one.
          </p>
          <p className="un-prose">
            <strong>Forfeit.</strong> Every round you must check in — one tap, no proof, no cost. Miss more than{" "}
            <Fact>{cfg?.maxMissedCheckIns ?? "a few"}</Fact> in a row and you are eliminated. It exists because the
            chain genuinely cannot tell who voted, so being alive needs a signal of its own. It is the stupid death:
            not outplayed, just absent.
          </p>
        </Section>

        <Section title="The prize">
          <p className="un-prose">
            One pot, and the last player standing takes all of it
            {feeToken.format(game?.pot) ? (
              <>
                {" "}
                — currently <Fact>{feeToken.format(game?.pot)}</Fact> {feeToken.symbol ?? ""}
              </>
            ) : null}
            .
          </p>
          <p className="un-prose">
            It is worth knowing that the pot pays for the game. Every round buys an encrypted vote, and that fee comes
            out of the same pot the winner eventually collects — so the prize shrinks a little with each elimination.
            The game consumes what it is played for.
          </p>
          <p className="un-note">
            {cfg?.entryFee && cfg.entryFee > 0n
              ? `Joining costs ${feeToken.format(cfg.entryFee) ?? cfg.entryFee.toString()} ${feeToken.symbol ?? ""}, which goes into the pot.`
              : "Joining is free. Whoever started this lobby put the pot up themselves, so playing costs you nothing but gas."}
          </p>
        </Section>

        <Section title="Winning">
          <p className="un-prose">
            At <Fact>{cfg?.finalists ?? "two"}</Fact> survivors the eliminations stop. Everyone who was voted out
            becomes the jury, and the jury decides which finalist takes the pot.
          </p>
          <p className="un-prose">
            So being eliminated is not leaving. It is changing jobs, from playing to judging. How you treated people on
            the way up decides whether they hand you the pot on the way out.
          </p>
        </Section>

        <Section title="Why any of this is hard">
          <p className="un-prose">
            Everything you <em>say</em> is attributable and permanent. Everything you <em>do</em> is not.
          </p>
          <p className="un-prose">
            A promise costs nothing to make and nothing to break, and nobody can ever prove you broke it — and everyone
            knows that about everyone. The public half is pure reputation with no enforcement behind it, and reputation
            still matters, because the people you burn are the ones who choose the winner.
          </p>
          <p className="un-prose">
            Which is the joke at the centre of it: the ballot makes lying free, and the jury makes it expensive anyway.
          </p>
        </Section>

        <Section title="The fine print">
          <ul className="un-rules-list">
            <li>
              One player, one vote. No weighting, no stacking — everybody carries exactly one credit into every round.
            </li>
            <li>
              A tie is broken by a draw from the tied options, seeded by the tally itself. Deterministic, and anyone can
              recompute it.
            </li>
            <li>
              If nobody votes, the round is void. No mandate, no victim — it runs again rather than eliminating whoever
              happens to be first in a list.
            </li>
            <li>
              A tribe reduced to one member is eliminated without a council vote. There is nobody to deliberate over,
              and a one-option ballot cannot be proved.
            </li>
            <li>
              Anyone can settle a round or open the next one. It is a clock, not a privilege, and nobody can stall the
              game by refusing.
            </li>
            <li>
              The tribes are {TRIBES.map((t) => t.name).join(", ")}. Colour is the fastest read on the board and means
              nothing else.
            </li>
          </ul>
        </Section>

        <div className="un-row" style={{ margin: "40px 0 20px" }}>
          <Link href={gameHref} className="un-btn" style={{ textDecoration: "none" }}>
            Take a seat
          </Link>
          <Link href="/" className="un-btn un-btn-ghost" style={{ textDecoration: "none" }}>
            Back
          </Link>
        </div>
      </div>
    </main>
  );
}

const Section: FC<{ title: string; children: ReactNode }> = ({ title, children }) => (
  <section style={{ marginTop: 44 }}>
    <h2 className="un-title" style={{ fontSize: 26, marginBottom: 14 }}>
      {title}
    </h2>
    <div className="un-stack" style={{ gap: 14 }}>
      {children}
    </div>
  </section>
);

const Phase: FC<{ name: string; length?: string; body: string }> = ({ name, length, body }) => (
  <div className="un-panel" style={{ padding: "16px 18px" }}>
    <div className="un-spread" style={{ marginBottom: 6 }}>
      <span className="un-label">{name}</span>
      {length && <span className="un-mono">{length}</span>}
    </div>
    <p className="un-note" style={{ margin: 0 }}>
      {body}
    </p>
  </div>
);

/// Numbers read from the contract, marked so a reader can see which parts are this game rather than
/// the game in general.
const Fact: FC<{ children: ReactNode }> = ({ children }) => <span className="un-rules-fact">{children}</span>;

function duration(seconds: bigint): string {
  const total = Number(seconds);
  if (total >= 3600) {
    const h = Math.floor(total / 3600);
    const m = Math.round((total % 3600) / 60);
    return m ? `${h}h ${m}m` : `${h}h`;
  }
  if (total >= 60) return `${Math.round(total / 60)}m`;
  return `${total}s`;
}
