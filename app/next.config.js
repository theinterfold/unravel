/** @type {import('next').NextConfig} */
const nextConfig = {
  // A production build writes to the same directory `next dev` is serving from, and dev chunk
  // filenames are regenerated on every compile — so building while the dev server is up makes an
  // already-open page request chunks that no longer exist ("Loading chunk ... failed"). Builds get
  // their own directory so the two cannot collide.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  trailingSlash: true,
  transpilePackages: ["@aragon/ods"],
  webpack: (config) => {
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};

module.exports = nextConfig;
