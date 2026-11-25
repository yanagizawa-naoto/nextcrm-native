const withNextIntl = require("next-intl/plugin")(
  "./i18n/request.ts"
);

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  ...(process.env.NEXTCRM_DESKTOP === "1" ? {
    cacheMaxMemorySize: 4 * 1024 * 1024,
    experimental: { preloadEntriesOnStart: false, isrFlushToDisk: false },
  } : {}),
  outputFileTracingIncludes: { "/api/invoices/*": ["./public/fonts/**/*"] },
  serverExternalPackages: ["pdf-parse", "pdfjs-dist", "googleapis"],
  images: {
    // Local desktop files are already on this Mac. Avoid an extra image cache
    // and runtime writes inside the signed application bundle.
    unoptimized: process.env.NEXTCRM_DESKTOP === "1",
    remotePatterns: [
      { protocol: "https", hostname: "localhost" },
      { protocol: "https", hostname: "res.cloudinary.com" },
      { protocol: "https", hostname: "lh3.googleusercontent.com" },
      { protocol: "https", hostname: "minio-cwg0o4ss0scoccgwso8sk004.coolify.cz" },
      { protocol: "http", hostname: "minio" },
    ],
  },
  async redirects() {
    return [
      {
        source: "/:locale/crm/targets/:path*",
        destination: "/:locale/campaigns/targets/:path*",
        permanent: true,
      },
      {
        source: "/:locale/crm/target-lists/:path*",
        destination: "/:locale/campaigns/target-lists/:path*",
        permanent: true,
      },
    ];
  },
};

module.exports = withNextIntl(nextConfig);
