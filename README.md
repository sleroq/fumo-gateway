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

## Model catalog schema

`GET /v1/models` returns `{"object":"list","data":[...]}`. Each catalog entry has:

| Field | Schema | Source |
| --- | --- | --- |
| `id` | string, required | `<upstream>/<native-id>` or `<upstream>/<alias>` |
| `object` | `"model"`, required | Gateway envelope |
| `owned_by` | string, required | Configured upstream namespace, not the upstream's owner field |
| `name` | string, optional | Upstream `name`, or SIWC `display_name` |
| `created` | integer, optional | Upstream timestamp, only when supplied and non-null |
| Other fields | any JSON value, optional | Native discovery fields, with their original names and nested structure |

For example, if SIWC discovery supplies these capabilities, an entry can contain:

```json
{
  "id": "codex/example-model",
  "object": "model",
  "owned_by": "codex",
  "name": "Example model",
  "slug": "example-model",
  "display_name": "Example model",
  "visibility": "list",
  "context_window": 272000,
  "input_modalities": ["text", "image"],
  "default_reasoning_level": "medium",
  "supported_reasoning_levels": [
    {"effort": "low", "description": "Fast"},
    {"effort": "high", "description": "Thorough"}
  ]
}
```

Standard OpenAI-compatible catalogs retain their native extensions too, such as
`context_length`, `architecture.input_modalities`, `top_provider.max_completion_tokens`,
`limits`, or `supported_parameters` **when returned by discovery**. These are
upstream-specific fields, not a universal capability schema: clients must check
presence and understand that upstream's field semantics. Unknown extensions are
preserved, including nested objects/arrays and explicit `false`, `0`, or `null`.
Missing metadata stays absent; the gateway does not infer capabilities, assign
protocols, populate model-family defaults, or consult a hard-coded model catalog.
A minimal entry is just `{"id":"zen/example","object":"model","owned_by":"zen"}`.

SIWC discovery still lists only entries with `visibility: "list"`, in server order.
Aliases appear first and inherit the discovered native target's name, timestamp,
and extensions; only `id` changes. If the target is unavailable, the alias has only
the gateway envelope. An alias shadowing another discovered ID never inherits
that shadowed model's metadata. Alias routing remains a single lookup, unchanged.

## Development

Build: `zig build`. Test: `zig build test` (local fixtures, no provider credentials).
Planned work: [ROADMAP.md](ROADMAP.md).
