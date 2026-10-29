# fumo-gateway

Headless LLM gateway with Responses forwarding, model aliases, and Sign in with ChatGPT.

Requires Zig **0.17.0** (`nix develop`). Configure `gateway.json` using
[`src/config.zig`](src/config.zig).

```sh
zig build run -- auth login codex
export FUMO_PI_KEY="$(openssl rand -hex 32)"
zig build run -- --config gateway.json
```

Tests: `zig build test`. Planned scope: [ROADMAP.md](ROADMAP.md).
