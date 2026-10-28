# fumo-gateway

A small, headless LLM gateway. See [ROADMAP.md](ROADMAP.md) for the planned scope.

## Run

```sh
export FUMO_PI_KEY="$(openssl rand -hex 32)"
export FUMO_DEV_KEY="$(openssl rand -hex 32)"
zig build run -- --config gateway.example.json
```

## Development

Requires Zig **0.17.0**, available through `nix develop`.

```sh
zig build
zig build test
zig fmt --check build.zig build.zig.zon src/
```
