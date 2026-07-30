import { RootContextProvider } from "@/context";
import { Layout } from "@/components/layout";
import AlertContainer from "@/components/alert/alert-container";
import { ErrorBoundary } from "@/components/errorBoundary";
import "@aragon/ods/index.css";
import "@/pages/globals.css";
// Last, so the game's own tokens win inside `.un` without needing specificity tricks.
//
// Lives outside plugins/ deliberately: that directory is glob-imported at runtime to discover
// plugins, and a stylesheet in there gets pulled into the glob and rejected as a non-App global CSS
// import.
import "@/styles/unravel.css";
import { PUB_APP_NAME } from "@/constants";
import Head from "next/head";

export default function AragonetteApp({ Component, pageProps }: any) {
  return (
    <>
      <Head>
        <title>{PUB_APP_NAME}</title>
      </Head>
      <RootContextProvider>
        <Layout>
          {/* Keyed on the page component so navigating away clears a crashed view. */}
          <ErrorBoundary key={Component?.name}>
            <Component {...pageProps} />
          </ErrorBoundary>
        </Layout>
        <AlertContainer />
      </RootContextProvider>
    </>
  );
}
