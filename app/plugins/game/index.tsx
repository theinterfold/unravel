import GamePage from "./pages/game";

/// The plugin loader (`pages/plugins/[id].tsx`) renders this default export.
///
/// UNRAVEL has a single view — there is only ever one game, one current round, one ballot — so
/// unlike the governance app this needs no internal routing.
export default function GamePlugin() {
  return <GamePage />;
}
