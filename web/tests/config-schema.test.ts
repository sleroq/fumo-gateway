import { expect, test } from "bun:test";
import { Ajv } from "ajv";
import schema from "../../schemas/v1/gateway.schema.json" with { type: "json" };
import example from "../../gateway.example.json" with { type: "json" };

const validate = new Ajv({ allErrors: true, strict: true }).compile(schema);

// The schema is loaded locally: no dependency on publishing it or fetching GitHub.
test("the example selects the published schema URL and validates locally", () => {
    expect(example.$schema).toBe(schema.$id);
    expect(validate(example), JSON.stringify(validate.errors)).toBe(true);
});

test("legacy and SIWC credentials require their respective endpoints", () => {
    for (const [provider, endpoint] of [
        ["codex", "https://api.openai.com/v1"],
        ["codex_legacy", "https://chatgpt.com/backend-api/codex"],
    ]) {
        for (const base_url of [
            "https://api.openai.com/v1",
            "https://chatgpt.com/backend-api/codex",
            "https://example.com",
        ]) {
            const config = { upstreams: { personal: { base_url, auth: { provider } } } };
            expect(validate(config)).toBe(base_url === endpoint);
        }
    }
});
