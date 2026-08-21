/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: { typedRoutes: true },
  serverExternalPackages: ["socket.io"]
};

export default nextConfig;
