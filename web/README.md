# Gateway admin

```sh
bun install --frozen-lockfile
bun dev
bun run lint
bun run typecheck
bun test # requires Chromium: bunx playwright install chromium
```

Run the gateway alongside Vite. API requests proxy to `http://127.0.0.1:8080`;
override with `ADMIN_API_TARGET`. `zig build` builds and embeds the production UI.
