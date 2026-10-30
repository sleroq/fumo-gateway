<img src="assets/logo.svg" alt="Fumo Gateway mascot" width="180">

# fumo-gateway

Headless LLM gateway with named upstreams, model discovery, and Sign in with ChatGPT.
Forwards native OpenAI Responses and Chat Completions requests; no protocol translation.

## Quick start

Requires Zig **0.17.0** and **Bun** (`nix develop`). Copy
[`gateway.example.json`](gateway.example.json), remove unused upstreams, and set
the provider API keys referenced by your configuration.

```sh
bun install --cwd web --frozen-lockfile
cp gateway.example.json gateway.json
export FUMO_PI_KEY="$(openssl rand -hex 32)"
export FUMO_ADMIN_KEY="$(openssl rand -hex 32)"
zig build
zig-out/bin/fumo-gateway --config gateway.json
```

For ChatGPT, open **http://127.0.0.1:8080/admin/**, unlock with `FUMO_ADMIN_KEY`.
For remote administration, use an SSH tunnel; do not expose admin access over plaintext HTTP.

Point your client at `http://127.0.0.1:8080/v1` with `FUMO_PI_KEY` as its bearer key.

## Development

Run `zig build test`, `zig build test-auth`, and `zig build test-service`.
Frontend checks: `bun run --cwd web lint`, `typecheck`, and `test` (each as a separate script).
For frontend development, run the gateway and `bun run --cwd web dev`.

Planned work: [ROADMAP.md](ROADMAP.md).
