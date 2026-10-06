import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./src/index.ts",
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: { ALLOWED_ORIGINS: "https://client.test" },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
