<img src="assets/logo.svg" alt="Fumo Gateway mascot" width="180">

# fumo-gateway

LLM gateway with named upstreams, model discovery. 

Forwards native OpenAI Responses and Chat Completions requests without any protocol translation.

Providers support:
- OpenAI (Both SWCG and Codex auth)
- Opencode zen / go
- Any other openai-compatible api with token-based auth

## Quick start

Clone this repository, copy [`gateway.example.json`](gateway.example.json) to
`gateway.json`, and remove unused upstreams. Create a `.env` file with your
client, admin, and any configured provider keys:

```sh
printf 'FUMO_PI_KEY=%s\nFUMO_ADMIN_KEY=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .env
```

Start with Nix:

```sh
set -a; . ./.env; set +a
nix run github:sleroq/fumo-gateway -- --config gateway.json
```

Or, for Docker Compose, set `"listen": "0.0.0.0:8080"` in `gateway.json`
so the gateway accepts connections inside the container, then run:

```sh
docker compose up -d
```

For ChatGPT, open **http://127.0.0.1:8080/admin/**, unlock with `FUMO_ADMIN_KEY`.

Use an SSH tunnel to access UI if you want to run fumo-gateway on the server; do not expose admin access. It is secure, but I would still avoid this as a practice.

Point your client at `http://127.0.0.1:8080/v1` with `FUMO_PI_KEY` as its bearer key.

## Outbound proxy

You can configure gateway to proxy all requests via http or socks5 proxy by setting `"proxy_env": "FUMO_PROXY"` in your configuration and exporting `FUMO_PROXY=http://127.0.0.1:8081` (or `socks5://127.0.0.1:1080`) env

For NixOS, use the [included module](nix/README.md).

## Client plugins

For ease of use in opencode and pi - use plugins. They automatically get the model information from the upstream providers and set all necessary capabilities, registering fumo as a provider automatically.

They are optional: any OpenAI-compatible client can use the gateway URL and client API key directly,
with model IDs and request options configured manually.

### Pi

```sh
pi install npm:@fumo-gateway/pi
```

Run `/login fumo`

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

Restart OpenCode, run `/connect`, choose **Fumo Gateway**

## Development

Run `cargo test` and `cargo clippy --workspace --all-targets --all-features -- -D warnings`.

The Rust build embeds the admin UI and runs the frontend build with Bun.


Frontend checks: `bun run --cwd web lint`, `typecheck`, and `test` (each as a separate script).
For frontend development, run the gateway and `bun run --cwd web dev`.

Planned work: [ROADMAP.md](ROADMAP.md).
