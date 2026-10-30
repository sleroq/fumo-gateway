import { expect, test } from "bun:test";
import { Ajv } from "ajv";
import schema from "../../schemas/v1/gateway.schema.json" with { type: "json" };
import example from "../../gateway.example.json" with { type: "json" };

const validate = new Ajv({ allErrors: true, strict: true }).compile(schema);

type CodexOverrides = { base_url?: string; auth?: unknown };

function upstream(options: unknown) {
    return { upstreams: { demo: options } };
}

function codex(options: CodexOverrides = {}) {
    return upstream({ base_url: "https://api.openai.com/v1", auth: { provider: "codex" }, ...options });
}

// The schema is loaded locally: no dependency on publishing it or fetching GitHub.
test("the example selects the published schema URL and validates locally", () => {
    expect(example.$schema).toBe(schema.$id);
    expect(validate(example), JSON.stringify(validate.errors)).toBe(true);
});

const valid = [
    {},
    { $schema: "./schemas/v1/gateway.schema.json" },
    { listen: "[::1]:8080", admin: null },
    { admin: {} },
    { admin: { key_env: "ADMIN_KEY" }, clients: { pi: { key_env: "PI_KEY" } } },
    upstream({ base_url: "http://localhost:9090/v1/", aliases: { fast: "vendor/model" } }),
    upstream({ base_url: "http://[::1]:9090/v1", auth: null }),
    upstream({ base_url: "HTTPS://example.com/v1", auth: { provider: "api_key", key_env: "API_KEY" } }),
    upstream({ base_url: "http://localhost/v1", auth: { provider: "api_key", key_env: "API_KEY", credentials_dir: null } }),
    codex(),
    codex({ base_url: "https://api.openai.com/v1///" }),
    codex({ auth: { provider: "codex", credentials_dir: "/private/credentials" } }),
    codex({ auth: { provider: "codex", credentials_dir: null, key_env: null } }),
];

for (const config of valid) {
    test(`accepts ${JSON.stringify(config)}`, () => {
        expect(validate(config), JSON.stringify(validate.errors)).toBe(true);
    });
}

const invalid = [
    null,
    [],
    { typo: true },
    { $schema: 1 },
    { listen: 8080 },
    { listen: "localhost:8080" },
    { listen: "127.0.0.1" },
    { admin: { typo: true } },
    { admin: { key_env: "" } },
    { clients: [] },
    { clients: { "": { key_env: "KEY" } } },
    { clients: { pi: {} } },
    { clients: { pi: { key_env: "KEY", typo: true } } },
    { clients: { pi: { key_env: "BAD=KEY" } } },
    { clients: { pi: { key_env: "BAD\u0000KEY" } } },
    { upstreams: { "bad/name": { base_url: "http://localhost/v1" } } },
    { upstreams: { "": { base_url: "http://localhost/v1" } } },
    upstream({}),
    upstream({ base_url: "ftp://example.com/v1" }),
    upstream({ base_url: "https:///v1" }),
    upstream({ base_url: "https://user:password@example.com/v1" }),
    upstream({ base_url: "https://example.com/v1?query" }),
    upstream({ base_url: "https://example.com/v1#fragment" }),
    upstream({ base_url: "http://localhost/v1", protocol: "chat_completions" }),
    upstream({ base_url: "http://localhost/v1", aliases: { "": "model" } }),
    upstream({ base_url: "http://localhost/v1", aliases: { fast: "" } }),
    upstream({ base_url: "http://localhost/v1", auth: {} }),
    upstream({ base_url: "http://localhost/v1", auth: { provider: "unknown" } }),
    upstream({ base_url: "http://localhost/v1", auth: { provider: "api_key" } }),
    upstream({ base_url: "http://localhost/v1", auth: { provider: "api_key", key_env: null } }),
    upstream({ base_url: "http://localhost/v1", auth: { provider: "api_key", key_env: "API_KEY", credentials_dir: "/private" } }),
    codex({ auth: { provider: "codex", key_env: "API_KEY" } }),
    codex({ auth: { provider: "codex", credentials_dir: " \t\r\n" } }),
    codex({ auth: { provider: "codex", typo: true } }),
    ...["http://api.openai.com/v1", "https://example.com/v1", "https://api.openai.com:443/v1", "https://api.openai.com/other"].map(
        (base_url) => codex({ base_url }),
    ),
];

for (const config of invalid) {
    test(`rejects ${JSON.stringify(config)}`, () => {
        expect(validate(config)).toBe(false);
    });
}
