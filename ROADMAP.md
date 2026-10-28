## V1 requirements

**Goal:** A small, headless LLM gateway that centralizes subscription credentials, outbound connections, and metrics—not a general-purpose API compatibility platform.

### Supported upstreams
- **Codex subscriptions:** device-code login, automatic token refresh, secure credential persistence, and Responses API access.
- **OpenCode Go and Zen:** API-key authentication, configured as separate upstreams.
- Initially **one upstream credential per provider**; no account pooling or automatic failover.

### Request handling
- Expose each model through its **native protocol**: Responses, Chat Completions
- Support HTTP streaming and non-streaming requests.
- Preserve tools, reasoning, images, and session identity supported by the native protocol.
- Propagate cancellation and upstream errors; never automatically replay a partially delivered response.
- No server-side agent loop or tool execution.

### Configuration and access
- Declarative configuration for upstreams, supported models/protocols, aliases, client keys, and outbound proxies.
- Secrets supplied separately from configuration.
- Configuration changes take effect on restart; only OAuth credential state is mutable.
- Multiple labeled client keys; no management API or configuration UI.
- HTTP CONNECT and SOCKS5 proxy support, applied consistently to inference, authentication, and supporting upstream calls.

### Observability
- Prometheus metrics for requests, failures, latency, time to first token, and reported token/cache usage, labeled by client, upstream, and model.
- Subscription quota and reset metrics where available.
- Structured diagnostic logs; no prompt/response-content logging or secret exposure.

### Maintainability
- Keep provider-specific behavior isolated.
- Prefer transparent forwarding; use a maintained dependency when substantial compatibility logic is necessary.
- Adapt our Pi integration to select each model’s native protocol.

### Explicitly out of scope
Universal protocol translation, WebSockets, automatic model-family guessing, account rotation, cross-provider fallback, image generation, provider-hosted tools, and full native Codex CLI compatibility.

**Acceptance:** Pi agent can complete multi-turn tool-using sessions through Codex and the supported Go/Zen protocols, including through an outbound proxy, with working refresh, cancellation, and metrics.

## References for implementation

- ChatGPT auth and sse streaming - https://github.com/router-for-me/CLIProxyAPI
- Opencode Go - https://github.com/massiveits/opencode-go-cliproxyapi
