import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: ["class"],
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          50: "#eff6ff", 100: "#dbeafe", 400: "#60a5fa", 500: "#3b82f6",
          600: "#2563eb", 700: "#1d4ed8", 900: "#1e3a8a"
        }
      },
      boxShadow: {
        soft: "0 12px 40px rgba(15, 23, 42, .10)"
      },
      animation: { "fade-in": "fade-in .2s ease-out" },
      keyframes: { "fade-in": { "0%": { opacity: "0", transform: "translateY(4px)" }, "100%": { opacity: "1", transform: "translateY(0)" } } }
    }
  },
  plugins: []
};
export default config;
