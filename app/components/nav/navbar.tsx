import WalletContainer from "@/components/WalletContainer";
import { plugins } from "@/plugins";
import Link from "next/link";
import { useState } from "react";
import { MobileNavDialog } from "./mobileNavDialog";
import { NavLink, type INavLink } from "./navLink";
import { Button, Spinner } from "@aragon/ods";
import { PUB_APP_NAME, PUB_ENABLE_FAUCET } from "@/constants";
import { useFaucet } from "@/hooks/useFaucet";
import { If } from "@/components/if";
import { useAlerts } from "@/context/Alerts";

export const Navbar: React.FC = () => {
  const [showMenu, setShowMenu] = useState(false);

  const { addAlert } = useAlerts();

  const navLinks: INavLink[] = [
    { path: "/", id: "dashboard", name: "Home" },
    { path: "/rules", id: "rules", name: "Rules" },
    ...plugins.map((p) => ({
      id: p.id,
      name: p.title,
      path: `/plugins/${p.id}/#/`,
      // icon: p.icon,
    })),
  ];

  const { claim, canClaim, blockedReason, isConfirming } = useFaucet();

  // The faucet tops up per token; blockedReason mirrors its own revert conditions
  // so a repeat click explains itself instead of burning a reverting transaction.
  const claimTestTokens = () => {
    if (!canClaim) {
      addAlert(blockedReason ?? "Cannot claim from the faucet right now");
      return;
    }
    claim();
  };

  return (
    <>
      {/* The wordmark is set type, not an image: a rename costs one line, and the Interfold logo it
          replaced was drawn for a light background. */}
      <nav className="un-nav">
        <div className="un-nav-inner">
          <div className="un-nav-top">
            <Link href="/" className="un-nav-brand">
              {PUB_APP_NAME}
            </Link>

            <div className="flex items-center gap-x-2 pb-3">
              <If true={PUB_ENABLE_FAUCET}>
                <div className="shrink-0">
                  <Button className="btn-mint" onClick={claimTestTokens} disabled={isConfirming} title={blockedReason}>
                    {isConfirming ? <Spinner size="sm" /> : "Faucet"}
                  </Button>
                </div>
              </If>
              <div className="shrink-0">
                <WalletContainer />
              </div>

              {/* Nav Trigger */}
              <button onClick={() => setShowMenu(true)} className="un-nav-trigger" aria-label="Menu">
                Menu
              </button>
            </div>
          </div>

          {/* Tab wrapper */}
          <ul className="un-nav-tabs">
            {navLinks.map(({ id, name, path }) => (
              <NavLink name={name} path={path} id={id} key={id} />
            ))}
          </ul>
        </div>
      </nav>
      <MobileNavDialog open={showMenu} navLinks={navLinks} onOpenChange={setShowMenu} />
    </>
  );
};
