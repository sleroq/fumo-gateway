import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createProvider, envApiKeyAuth, getSupportedThinkingLevels, InMemoryModelsStore, Type, type Context } from "@earendil-works/pi-ai";
import { openAIResponsesApi } from "@earendil-works/pi-ai/compat";
import { ModelRuntime, readStoredCredential } from "@earendil-works/pi-coding-agent";
import { parseCatalog } from "../catalog";
import gatewayCatalog from "../../tests/fixtures/model-catalog.json";
import extension, { createFumoProvider, toPiModel } from "./index";

const entries = await parseCatalog(Response.json(gatewayCatalog));
const directories: string[] = [];
const refresh = { providers: ["fumo"] };
let environmentKey: string | undefined;
beforeEach(() => {
  environmentKey = process.env.FUMO_PI_KEY;
  delete process.env.FUMO_PI_KEY;
});
afterEach(() => {
  mock.restore();
  if (environmentKey === undefined) delete process.env.FUMO_PI_KEY;
  else process.env.FUMO_PI_KEY = environmentKey;
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

async function createRuntime(modelsStore = new InMemoryModelsStore(), baseUrl = "http://localhost:8080/v1") {
  const directory = mkdtempSync(join(tmpdir(), "pi-fumo-"));
  directories.push(directory);
  const authPath = join(directory, "auth.json");
  writeFileSync(authPath, JSON.stringify({ other: { type: "api_key", key: "other-key" } }), { mode: 0o600 });
  const runtime = await ModelRuntime.create({ authPath, modelsStore, modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(createFumoProvider({ baseUrl }));
  return { runtime, authPath, modelsStore };
}

async function login(runtime: ModelRuntime) {
  await runtime.login("fumo", "api_key", {
    prompt: async ({ type }) => type === "text" ? "" : "fixture-client-key", notify() {},
  });
}

async function discover(baseUrl?: string) {
  const state = await createRuntime(undefined, baseUrl);
  await login(state.runtime);
  spyOn(globalThis, "fetch").mockResolvedValue(Response.json(gatewayCatalog));
  expect((await state.runtime.refresh(refresh)).errors.size).toBe(0);
  return state;
}

test("shared discovery maps Pi metadata and aliases without installed catalog enrichment", () => {
  const models = entries.map((entry) => toPiModel(entry, "http://localhost:8080/v1"));
  for (const id of ["personal/fast", "personal/gpt-6.1-sol"]) {
    const model = models.find((model) => model.id === id)!;
    expect(model).toMatchObject({
      name: "Personal Codex", contextWindow: 272000, maxTokens: 16000,
      input: ["text", "image"], reasoning: true,
      compat: { supportsMaxOutputTokens: false, supportsLongCacheRetention: false, supportsToolSearch: false },
    });
    expect(getSupportedThinkingLevels(model)).toEqual(["low", "high"]);
  }

  expect(models.find(({ id }) => id === "codex/gpt-6.1-sol")).toMatchObject({
    name: "API-key model", contextWindow: 128000, maxTokens: 16384, input: ["text"], reasoning: false,
  });
  expect(models.find(({ id }) => id === "personal/future")).toMatchObject({
    name: "personal/future", contextWindow: 128000, maxTokens: 16384, input: ["text"], reasoning: false,
  });
  expect(models.find(({ id }) => id === "zen/vendor/rich")).toMatchObject({
    api: "openai-completions", contextWindow: 200000, maxTokens: 32000, input: ["text", "image"],
  });
  expect(models.every((model) => model.inputLimits === undefined)).toBe(true);
});

test("login saves the gateway URL for discovery and both native adapters after restart", async () => {
  const { runtime, authPath } = await createRuntime();
  const prompts: string[] = [];
  await runtime.login("fumo", "api_key", {
    async prompt({ type, message }) {
      prompts.push(message);
      return type === "text" ? " https://saved-gateway.example.test/v1/ " : "fixture-client-key";
    },
    notify() {},
  });
  expect(prompts).toEqual(["Gateway URL (including /v1)", "Enter Fumo client API key"]);
  expect(readStoredCredential("fumo", authPath)).toEqual({
    type: "api_key", key: "fixture-client-key", env: { FUMO_BASE_URL: "https://saved-gateway.example.test/v1" },
  });

  const restarted = await ModelRuntime.create({ authPath, modelsPath: null, refreshOnCreate: false });
  restarted.registerNativeProvider(createFumoProvider());
  const fetch = spyOn(globalThis, "fetch").mockResolvedValue(Response.json(gatewayCatalog));
  expect((await restarted.refresh(refresh)).errors.size).toBe(0);
  expect(fetch.mock.calls[0][0]).toBe("https://saved-gateway.example.test/v1/models");
  expect((await restarted.getAuth("fumo"))?.auth).toEqual({
    apiKey: "fixture-client-key", baseUrl: "https://saved-gateway.example.test/v1",
  });
  for (const [id, route] of [["personal/fast", "responses"], ["zen/vendor/rich", "chat/completions"]]) {
    expect((await nativeRequest(restarted, id)).request.url).toBe(`https://saved-gateway.example.test/v1/${route}`);
  }
});

test("existing key-only credentials keep the configured gateway URL", async () => {
  const { runtime, authPath } = await createRuntime(undefined, "https://managed-gateway.example.test/v1");
  writeFileSync(authPath, JSON.stringify({ fumo: { type: "api_key", key: "existing-key" } }));
  expect((await runtime.getAuth("fumo"))?.auth).toEqual({
    apiKey: "existing-key", baseUrl: "https://managed-gateway.example.test/v1",
  });
  const fetch = spyOn(globalThis, "fetch").mockResolvedValue(Response.json(gatewayCatalog));
  expect((await runtime.refresh(refresh)).errors.size).toBe(0);
  expect(fetch.mock.calls[0][0]).toBe("https://managed-gateway.example.test/v1/models");
});

test("invalid URL or cancelled login leaves the existing credentials unchanged", async () => {
  const { runtime, authPath } = await createRuntime();
  await login(runtime);
  const saved = readStoredCredential("fumo", authPath);
  for (const url of ["not a URL", "file:///tmp/gateway"]) {
    await expect(runtime.login("fumo", "api_key", { prompt: async () => url, notify() {} })).rejects.toThrow();
    expect(readStoredCredential("fumo", authPath)).toEqual(saved);
  }
  await expect(runtime.login("fumo", "api_key", {
    async prompt({ type }) {
      if (type === "text") return "https://another-gateway.example.test/v1";
      throw new Error("Login cancelled");
    },
    notify() {},
  })).rejects.toThrow("Login cancelled");
  expect(readStoredCredential("fumo", authPath)).toEqual(saved);
});

test("native login, refresh, cache retention, failures, and cancellation preserve provider isolation", async () => {
  const { runtime, authPath, modelsStore } = await createRuntime();
  const refreshOther = mock(async () => []);
  runtime.registerNativeProvider(createProvider({
    id: "other", auth: { apiKey: envApiKeyAuth("other key", []) },
    models: [], fetchModels: refreshOther, api: openAIResponsesApi(),
  }));
  const fetch = spyOn(globalThis, "fetch").mockResolvedValue(Response.json(gatewayCatalog));
  await runtime.refresh(refresh);
  expect(fetch).not.toHaveBeenCalled();
  process.env.FUMO_PI_KEY = "environment-key";
  expect((await runtime.getAuth("fumo"))?.auth.apiKey).toBe("environment-key");
  await login(runtime);
  expect((await runtime.getAuth("fumo"))?.auth.apiKey).toBe("fixture-client-key");
  expect((await runtime.refresh(refresh)).errors.size).toBe(0);
  expect(fetch.mock.calls[0][0]).toBe("http://localhost:8080/v1/models");
  expect(fetch.mock.calls[0][1]?.headers).toEqual({ Authorization: "Bearer fixture-client-key" });

  const restarted = await createRuntime(modelsStore);
  await restarted.runtime.refresh({ ...refresh, allowNetwork: false });
  expect(restarted.runtime.getModels("fumo")).toEqual(runtime.getModels("fumo"));
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(JSON.stringify(await modelsStore.read("fumo"))).not.toContain("fixture-client-key");
  fetch.mockResolvedValue(new Response("private upstream body", { status: 503 }));
  expect((await runtime.refresh(refresh)).errors.get("fumo")?.message).toBe("fumo model discovery failed (HTTP 503).");
  expect(runtime.getModels("fumo").map(({ id }) => id)).toEqual(entries.map(({ id }) => id));

  const started = Promise.withResolvers<void>();
  fetch.mockImplementation(Object.assign(async (...[_url, options]: Parameters<typeof globalThis.fetch>) => {
    const signal = options?.signal;
    if (!signal) throw new Error("Discovery must supply a signal");
    return new Promise<Response>((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      started.resolve();
    });
  }, { preconnect() {} }));
  const controller = new AbortController();
  const pending = runtime.refresh({ ...refresh, signal: controller.signal });
  await started.promise;
  controller.abort();
  expect((await pending).aborted).toBe(true);
  expect(runtime.getModels("fumo").map(({ id }) => id)).toEqual(entries.map(({ id }) => id));
  expect(refreshOther).not.toHaveBeenCalled();
  await runtime.logout("fumo");
  expect(readStoredCredential("fumo", authPath)).toBeUndefined();
  expect(readStoredCredential("other", authPath)).toEqual({ type: "api_key", key: "other-key" });
});

const context: Context = {
  messages: [
    { role: "system", content: "Fixture instructions", timestamp: 0, toolsAdded: [
      { name: "fixture_read", description: "Read a fixture", parameters: Type.Object({ path: Type.String() }) },
    ] },
    { role: "user", content: "Read the fixture", timestamp: 1 },
  ],
};

async function nativeRequest(runtime: ModelRuntime, id: string, cacheRetention: "long" | "none" = "long") {
  const requests: Request[] = [];
  spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: string | URL | Request, init?: RequestInit) => {
    const request = new Request(input, init);
    requests.push(request);
    const event = request.url.endsWith("/responses") ? {
      type: "response.completed",
      response: {
        id: "fixture-response", object: "response", created_at: 0, status: "completed", model: id,
        output: [], usage: { input_tokens: 1, output_tokens: 0, total_tokens: 1 },
      },
    } : {
      id: "fixture-chat", object: "chat.completion.chunk", created: 0, model: id,
      choices: [{ index: 0, delta: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    };
    return new Response(`data: ${JSON.stringify(event)}\n\ndata: [DONE]\n\n`, {
      headers: { "Content-Type": "text/event-stream" },
    });
  }, { preconnect() {} }));
  const result = await runtime.completeSimple(runtime.getModel("fumo", id)!, context, {
    maxTokens: 100, reasoning: "high", cacheRetention, sessionId: "fixture-session",
  });
  expect(result.errorMessage).toBeUndefined();
  expect(requests).toHaveLength(1);
  expect(requests[0].headers.get("authorization")).toBe("Bearer fixture-client-key");
  const payload = await requests[0].json();
  expect(payload.model).toBe(id);
  return { request: requests[0], payload };
}

test("constrained native Responses keeps full IDs, tools, effort updates, and explicit cache mode", async () => {
  const { runtime } = await discover("https://gateway.example.test/v1");
  const { request, payload } = await nativeRequest(runtime, "personal/gpt-6.1-sol");
  expect(request.url).toBe("https://gateway.example.test/v1/responses");
  expect(payload).toMatchObject({ stream: true, store: false, prompt_cache_key: "fixture-session" });
  expect(payload.input).toBeArray();
  for (const field of entries[0].request_constraints!.responses.omit) expect(payload).not.toHaveProperty(field);
  expect(payload.tools).toBeUndefined();
  expect(payload.input).toContainEqual(expect.objectContaining({
    type: "additional_tools", role: "developer", tools: [expect.objectContaining({ name: "fixture_read", type: "function" })],
  }));
  expect(payload.input.some((item: { type?: string }) => item.type?.startsWith("tool_search"))).toBe(false);
  expect(payload.input).toContainEqual({ type: "configuration_update", reasoning: { effort: "high" } });
  expect(payload.reasoning.effort).toBe("medium");
  expect((await nativeRequest(runtime, "personal/gpt-6.1-sol", "none")).payload.prompt_cache_options).toEqual({ mode: "explicit" });

  const alias = (await nativeRequest(runtime, "personal/fast")).payload;
  expect(alias.max_output_tokens).toBeUndefined();
  expect(alias.reasoning.effort).toBe("high");
  expect(alias.input).toContainEqual(expect.objectContaining({ type: "additional_tools" }));
});

test("API-key codex namespace preserves native output/cache controls without inventing reasoning metadata", async () => {
  const { runtime } = await discover();
  const known = (await nativeRequest(runtime, "codex/gpt-6.1-sol")).payload;
  expect(known.max_output_tokens).toBe(100);
  expect(known.prompt_cache_options).toEqual({ ttl: "30m" });
  expect(known.reasoning).toBeUndefined();
  const alias = (await nativeRequest(runtime, "codex/quick")).payload;
  expect(alias.max_output_tokens).toBe(100);
  expect(alias.prompt_cache_retention).toBe("24h");
});

test("actual native Completions serialization uses the advertised route and output control", async () => {
  const { runtime } = await discover();
  const { request, payload } = await nativeRequest(runtime, "zen/vendor/rich");
  expect(request.url).toBe("http://localhost:8080/v1/chat/completions");
  expect(payload.messages).toBeArray();
  expect(payload.input).toBeUndefined();
  expect(payload.max_completion_tokens).toBe(100);
});

test("extension configures the native provider from the environment without custom commands", () => {
  const previous = process.env.FUMO_BASE_URL;
  process.env.FUMO_BASE_URL = "https://gateway.example.test/v1";
  try {
    const api = { registerProvider: mock(), registerCommand: mock() };
    extension(api);
    expect(api.registerProvider).toHaveBeenCalledTimes(1);
    expect(api.registerProvider.mock.calls[0][0].id).toBe("fumo");
    expect(api.registerProvider.mock.calls[0][0].baseUrl).toBe("https://gateway.example.test/v1");
    expect(api.registerCommand).not.toHaveBeenCalled();
  } finally {
    if (previous === undefined) delete process.env.FUMO_BASE_URL;
    else process.env.FUMO_BASE_URL = previous;
  }
});
