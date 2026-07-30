import { PUB_APP_NAME, PUB_BLOG_URL, PUB_SOCIALS_URL, PUB_PROJECT_URL, PUB_CHAIN } from "@/constants";

export const Footer = () => {
  const year = new Date().getFullYear();

  return (
    <footer className="un-foot">
      <div className="un-foot-inner">
        <div className="un-label-dim" style={{ lineHeight: 1.7, maxWidth: "44ch" }}>
          Campaign in the open. Vote by a ballot nobody can open. Secret elimination votes on the Interfold.
        </div>
        <ul className="un-foot-links">
          <li>
            <a href={PUB_PROJECT_URL} target="_blank" rel="noreferrer">
              {PUB_APP_NAME}
            </a>
          </li>
          <li>
            <a href={PUB_BLOG_URL} target="_blank" rel="noreferrer">
              Blog
            </a>
          </li>
          <li>
            <a href={PUB_SOCIALS_URL} target="_blank" rel="noreferrer">
              X (Twitter)
            </a>
          </li>
        </ul>
      </div>
      <div className="un-foot-rule">
        <span>
          © {year} {PUB_APP_NAME}
        </span>
        <span>{PUB_CHAIN.name}</span>
      </div>
    </footer>
  );
};
