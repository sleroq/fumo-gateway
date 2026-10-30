<img src="assets/logo.svg" alt="Fumo Gateway mascot" width="180">

# fumo-gateway

Headless LLM gateway with named upstreams, model discovery, and Sign in with ChatGPT.
Forwards native OpenAI Responses and Chat Completions requests; no protocol translation.

## Quick start

Requires Zig **0.17.0** (`nix develop`). Copy
[`gateway.example.json`](gateway.example.json) to `gateway.json`, remove unused
upstreams, and set API keys for those you keep.

```sh
cp gateway.example.json gateway.json
export FUMO_PI_KEY="$(openssl rand -hex 32)"
zig build run -- auth login codex # Only needed for Codex.
zig build run -- --config gateway.json
```

Point your client at `http://127.0.0.1:8080/v1` with `FUMO_PI_KEY` as its bearer key.
Use `upstream/model-id` as the model; optional aliases live in each upstream's
`aliases` map. Choose the model's native API: `/responses` or `/chat/completions`.
Codex supports Responses only.

Discover available model IDs:

```sh
curl -H "Authorization: Bearer $FUMO_PI_KEY" http://127.0.0.1:8080/v1/models
```

## Development

Build: `zig build`. Test: `zig build test` (local fixtures, no provider credentials).
Planned work: [ROADMAP.md](ROADMAP.md).
