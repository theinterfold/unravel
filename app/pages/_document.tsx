import { Html, Head, Main, NextScript } from "next/document";

export default function Document() {
  return (
    <Html lang="en">
      <Head>
        <link rel="apple-touch-icon" sizes="76x76" href="/apple-touch-icon.png" />
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png" />
        <link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png" />
        {/* Interfold typography: Source Serif 4 (display/editorial) + JetBrains Mono (labels).
            `crossOrigin` is required, not cosmetic: the app ships Cross-Origin-Embedder-Policy
            require-corp so bb.js can use SharedArrayBuffer for threaded proving, and under COEP a
            cross-origin stylesheet fetched without CORS is blocked outright. Without this the fonts
            silently vanish in production while working perfectly in dev. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" crossOrigin="anonymous" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,500;1,8..60,400;1,8..60,500&display=swap"
          rel="stylesheet"
          crossOrigin="anonymous"
        />
        {/* UNRAVEL's three voices: Playfair is the ceremony, Poppins is the machine you operate,
            IBM Plex Mono is the chain's own voice. Loaded alongside the Interfold faces above
            rather than replacing them, because only the game surfaces use them. */}
        <link
          href="https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,400;0,500;1,400;1,500&family=Poppins:wght@400;500;600;700;800&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
          crossOrigin="anonymous"
        />
      </Head>
      {/* The ground behind every page. Light here would show through as a seam under the
          navbar and below short pages. */}
      <body style={{ background: "#0e1211" }}>
        <Main />
        <NextScript />
      </body>
    </Html>
  );
}
