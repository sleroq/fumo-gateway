<img src="assets/logo.svg" alt="Fumo Gateway mascot" width="180">

# fumo-gateway

Headless LLM gateway with named upstreams, model discovery, and Sign in with ChatGPT.
Forwards native OpenAI Responses and Chat Completions requests; no protocol translation.

## Quick start

Requires **Rust** and **Bun** (`nix develop`). Copy
[`gateway.example.json`](gateway.example.json), remove unused upstreams, and set
the provider API keys referenced by your configuration.

```sh
bun install --cwd web --frozen-lockfile
cp gateway.example.json gateway.json
export FUMO_PI_KEY="$(openssl rand -hex 32)"
export FUMO_ADMIN_KEY="$(openssl rand -hex 32)"
cargo build --release
./target/release/fumo-gateway --config gateway.json
```

For ChatGPT, open **http://127.0.0.1:8080/admin/**, unlock with `FUMO_ADMIN_KEY`.
For remote administration, use an SSH tunnel; do not expose admin access over plaintext HTTP.

Point your client at `http://127.0.0.1:8080/v1` with `FUMO_PI_KEY` as its bearer key.

## Outbound proxy

Set `"proxy_env": "FUMO_PROXY"` in your configuration and export
`FUMO_PROXY=http://127.0.0.1:8081` (or `socks5://127.0.0.1:1080`), then restart.
Omit `proxy_env` for direct connections; conventional proxy variables are ignored.

## Nix

```sh
nix run github:sleroq/fumo-gateway
```

For NixOS, use the [included module](nix/README.md).

## Client plugins

The plugins discover available models and configure native adapters from Fumo's
metadata, including Sign in with ChatGPT request restrictions. They are optional:
any OpenAI-compatible client can use the gateway URL and client API key directly,
with model IDs and request options configured manually.

Authenticate with a **gateway client API key** (`FUMO_PI_KEY` in the quick start), not the admin key or upstream tokens.

### Pi

```sh
pi install npm:@fumo-gateway/pi
pi
```

Run `/login fumo`, enter the gateway URL (including `/v1`) and client key.

### OpenCode

Add to `opencode.json`:

```json
{
  "plugins": [{
    "package": "@fumo-gateway/opencode",
    "options": { "baseURL": "http://localhost:8080/v1" }
  }]
}
```

Restart OpenCode, run `/connect`, choose **Fumo Gateway**, and enter the client key.
Select a model with `/models`. Models refresh at startup and on account switches;
restart OpenCode to retry discovery or pick up gateway catalog changes.

## Development

Run `cargo test` and `cargo clippy --workspace --all-targets --all-features -- -D warnings`.
The Rust build embeds the admin UI and runs the frontend build with Bun.
Frontend checks: `bun run --cwd web lint`, `typecheck`, and `test` (each as a separate script).
For frontend development, run the gateway and `bun run --cwd web dev`.

Planned work: [ROADMAP.md](ROADMAP.md).
