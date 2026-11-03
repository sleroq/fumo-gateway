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
