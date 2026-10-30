import { afterEach, expect, mock, spyOn, test } from "bun:test";
import fixture from "../tests/fixtures/model-catalog.json";
import { discoverModels, modelMetadata, parseCatalog } from "./catalog";

afterEach(() => mock.restore());

test("one gateway catalog supplies both clients without namespace policy or invented metadata", async () => {
  const entries = await parseCatalog(Response.json(fixture));
  expect(entries.map((entry) => Boolean(modelMetadata(entry).constraints))).toEqual([true, true, true, false, false, false, false]);
  const [alias, sparse, , apiKey, , , nested] = entries.map(modelMetadata);
  expect(alias).toMatchObject({ id: "personal/fast", name: "Personal Codex", context: 272000, output: 16000, input: ["text", "image"], efforts: ["low", "high"] });
  expect(sparse).toMatchObject({ id: "personal/future", context: undefined, output: undefined, input: undefined, efforts: undefined });
  expect(apiKey).toMatchObject({ id: "codex/quick", api: "openai-responses", constraints: undefined, context: 128000 });
  expect(nested).toMatchObject({ id: "zen/vendor/rich", api: "openai-completions", context: 200000, output: 32000, input: ["text", "image"] });
});

test("metadata alternatives, nulls and explicit empty capabilities have one interpretation", async () => {
  const [entry] = await parseCatalog(Response.json(fixture));
  const metadata = modelMetadata({
    ...entry, context_window: null, context_length: 64000, max_output_tokens: null,
    top_provider: { max_completion_tokens: 8000 }, input_modalities: [], supported_reasoning_levels: [],
  });
  expect(metadata).toMatchObject({ context: 64000, output: 8000, input: [], efforts: [] });
  expect(modelMetadata({ ...entry, api: "openai-completions" }).constraints).toBeUndefined();
});

test("discovery validates its boundary and filters image-only models", async () => {
  const [entry] = await parseCatalog(Response.json(fixture));
  expect(await parseCatalog(Response.json({ data: [entry, { id: "images/gpt-image-1" }] }))).toEqual([entry]);
  for (const body of [{ data: [{}] }, { data: [{ id: "unnamespaced" }] }, { data: [{ ...entry, api: "unsupported" }] }, { data: [{ ...entry, request_constraints: { responses: { omit: false } } }] }]) {
    await expect(parseCatalog(Response.json(body))).rejects.toThrow("invalid model catalog");
  }
});

test("shared discovery sends only the gateway key, forwards cancellation, and reports HTTP errors", async () => {
  const controller = new AbortController();
  const fetch = spyOn(globalThis, "fetch").mockResolvedValueOnce(Response.json(fixture)).mockResolvedValueOnce(new Response(null, { status: 503 }));
  await discoverModels("https://gateway.example.test/v1", "client-key", controller.signal);
  const [url, options] = fetch.mock.calls[0];
  expect(url).toBe("https://gateway.example.test/v1/models");
  expect(options?.headers).toEqual({ Authorization: "Bearer client-key" });
  expect(options?.signal?.aborted).toBe(false);
  controller.abort();
  expect(options?.signal?.aborted).toBe(true);
  await expect(discoverModels("https://gateway.example.test/v1", "client-key", new AbortController().signal)).rejects.toThrow("HTTP 503");
});
