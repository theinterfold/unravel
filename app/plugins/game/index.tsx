import GamePage from "./pages/game";
import { ActiveGameProvider } from "./utils/activeGame";

/// The plugin loader (`pages/plugins/[id].tsx`) renders this default export.
///
/// The provider sits here rather than in `_app` because the selected lobby is this plugin's
/// concern: nothing outside it has a game address to care about, and scoping the state to the
/// plugin keeps the rest of the app unaware that lobbies exist.
export default function GamePlugin() {
  return (
    <ActiveGameProvider>
      <GamePage />
    </ActiveGameProvider>
  );
}
