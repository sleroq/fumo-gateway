import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getSupportedThinkingLevels, InMemoryModelsStore, normalizeContext, Type, type Context, type SimpleStreamOptions } from "@earendil-works/pi-ai";
import { generateSummary, ModelRuntime, readStoredCredential } from "@earendil-works/pi-coding-agent";
import { parseCatalog } from "../catalog";
import gatewayCatalog from "../../tests/fixtures/model-catalog.json";
import { createFumoProvider, toPiModel } from "./index";

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
  expect(fetch.mock.calls[0][1]?.headers).toEqual({ Authorization: "Bearer fixture-client-key" });
  const model = restarted.getModel("fumo", "personal/fast")!;
  expect(model).toMatchObject({
    name: "Personal Codex", contextWindow: 272000, maxTokens: 16000,
    input: ["text", "image"], reasoning: true,
  });
  expect(getSupportedThinkingLevels(model)).toEqual(["low", "high"]);
  expect(model.samplingParams).toBeUndefined();
  expect(restarted.getModel("fumo", "personal/future")).toMatchObject({
    contextWindow: 128000, maxTokens: 16384, input: ["text"], reasoning: false,
  });
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



const context: Context = {
  messages: [
    { role: "system", content: "Fixture instructions", timestamp: 0, toolsAdded: [
      { name: "fixture_read", description: "Read a fixture", parameters: Type.Object({ path: Type.String() }) },
    ] },
    { role: "user", content: "Read the fixture", timestamp: 1 },
  ],
};

async function nativeRequest(runtime: ModelRuntime, id: string, cacheRetention: "long" | "none" = "long", requestContext = context, onPayload?: SimpleStreamOptions["onPayload"], extraOptions: SimpleStreamOptions = {}) {
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
  const result = await runtime.completeSimple(runtime.getModel("fumo", id)!, requestContext, {
    maxTokens: 100, reasoning: "high", cacheRetention, sessionId: "fixture-session", onPayload, ...extraOptions,
  });
  expect(result.errorMessage).toBeUndefined();
  expect(requests).toHaveLength(1);
  expect(requests[0].headers.get("authorization")).toBe("Bearer fixture-client-key");
  const payload = await requests[0].json();
  expect(payload.model).toBe(id);
  return { request: requests[0], payload };
}

test("constrained native Responses keeps full IDs, tools, and top-level effort", async () => {
  const { runtime } = await discover("https://gateway.example.test/v1");
  const { request, payload } = await nativeRequest(runtime, "personal/gpt-6.1-sol");
  expect(request.url).toBe("https://gateway.example.test/v1/responses");
  expect(request.headers.get("accept")).toBe("application/json");
  expect(request.headers.get("originator")).toBeNull();
  expect(payload).toMatchObject({ stream: true, store: false, prompt_cache_key: "fixture-session" });
  expect(payload.input).toContainEqual(expect.objectContaining({ role: "developer", content: "Fixture instructions" }));
  expect(payload.instructions).toBeUndefined();
  expect(payload.text).toBeUndefined();
  expect(payload.tool_choice).toBeUndefined();
  expect(payload.parallel_tool_calls).toBeUndefined();
  for (const field of entries[0].request_constraints!.responses.omit) expect(payload).not.toHaveProperty(field);
  expect(payload.tools).toBeUndefined();
  expect(payload.input).toContainEqual(expect.objectContaining({
    type: "additional_tools", role: "developer", tools: [expect.objectContaining({ name: "fixture_read", type: "function" })],
  }));
  expect(payload.input.some((item: { type?: string }) => item.type?.startsWith("tool_search"))).toBe(false);
  expect(payload.input.some((item: { type?: string }) => item.type === "configuration_update")).toBe(false);
  expect(payload.reasoning.effort).toBe("high");
  const withoutCache = (await nativeRequest(runtime, "personal/gpt-6.1-sol", "none")).payload;
  expect(withoutCache.prompt_cache_options).toBeUndefined();
  expect(withoutCache.prompt_cache_key).toBeUndefined();

  const alias = (await nativeRequest(runtime, "personal/fast")).payload;
  expect(alias.max_output_tokens).toBeUndefined();
  expect(alias.reasoning.effort).toBe("high");
  expect(alias.input).toContainEqual(expect.objectContaining({ type: "additional_tools" }));
});

test("legacy Responses metadata drives native flat tools and instructions", async () => {
  const legacy = {
    ...gatewayCatalog.data[0], id: "legacy/example",
    request_constraints: { responses: {
      ...entries[0].request_constraints!.responses, function_tools: "flat" as const, instructions: "You are a helpful assistant.",
    } },
  };
  const [parsed] = await parseCatalog(Response.json({ data: [legacy] }));
  expect(parsed.request_constraints?.responses).toEqual(legacy.request_constraints.responses);
  const { runtime } = await createRuntime();
  await login(runtime);
  spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ data: [legacy] }));
  expect((await runtime.refresh(refresh)).errors.size).toBe(0);
  const model = runtime.getModel("fumo", legacy.id)!;
  expect(model.samplingParams).toEqual({ instructions: "You are a helpful assistant." });
  expect(model.compat).toMatchObject({ supportsAdditionalTools: false, supportsMidConvoSystemMessages: false, supportsMidConvoEffort: false });

  const { request, payload } = await nativeRequest(runtime, legacy.id);
  expect(request.headers.get("accept")).toBe("text/event-stream");
  expect(request.headers.get("originator")).toBe("pi");
  expect(payload.instructions).toBe("Fixture instructions");
  expect(payload.text).toEqual({ verbosity: "low" });
  expect(payload.tool_choice).toBe("auto");
  expect(payload.parallel_tool_calls).toBe(true);
  expect(payload.tools[0].strict).toBeNull();
  expect(payload.tools).toContainEqual(expect.objectContaining({ name: "fixture_read", type: "function", parameters: expect.objectContaining({ properties: { path: { type: "string" } } }) }));
  expect(payload.input).toEqual([expect.objectContaining({ role: "user" })]);
  expect(payload.prompt_cache_key).toBe("fixture-session");

  const absent = (await nativeRequest(runtime, legacy.id, "long", { messages: [{ role: "user", content: "Hello", timestamp: 1 }] })).payload;
  expect(absent.instructions).toBe("You are a helpful assistant.");
  expect(absent.text).toEqual({ verbosity: "low" });
  expect(absent.tool_choice).toBe("auto");
  expect(absent.parallel_tool_calls).toBe(true);
  expect(absent.tools).toBeUndefined();
  expect(absent.input).toEqual([expect.objectContaining({ role: "user" })]);

  let observed: unknown;
  const hooked = (await nativeRequest(runtime, legacy.id, "long", context, (value) => {
    observed = value;
    if (!value || typeof value !== "object") throw new Error("Expected request object");
    return { ...value, metadata: { source: "hook" } };
  })).payload;
  expect(observed).toMatchObject({ instructions: "Fixture instructions" });
  expect(hooked.metadata).toEqual({ source: "hook" });
  const explicit = (await nativeRequest(runtime, legacy.id, "long", context, (value) => {
    expect(value).toMatchObject({ instructions: "Explicit", text: { verbosity: "high" }, tool_choice: "none", parallel_tool_calls: false, tools: [{ strict: false }] });
    if (!value || typeof value !== "object") throw new Error("Expected request object");
    return { ...value, tool_choice: "required", parallel_tool_calls: true };
  }, { samplingParams: { instructions: "Explicit", text: { verbosity: "high" }, tool_choice: "none", parallel_tool_calls: false, tools: [{ type: "function", name: "explicit", parameters: {}, strict: false }] } })).payload;
  expect(explicit).toMatchObject({ tool_choice: "required", parallel_tool_calls: true, tools: [{ strict: false }] });

  const strictContext: Context = { messages: [
    { role: "system", content: "Strict", timestamp: 0, toolsAdded: [{ name: "strict_tool", description: "Strict tool", parameters: Type.Object({ value: Type.String() }), constrainedSampling: { type: "json_schema", strict: "require" } }] },
    { role: "user", content: "Hello", timestamp: 1 },
  ] };
  expect((await nativeRequest(runtime, legacy.id, "long", strictContext)).payload.tools[0].strict).toBe(true);

  const withSections = (await nativeRequest(runtime, legacy.id, "long", { messages: [
    { role: "system", content: "Base", sections: { policy: "Policy text" }, timestamp: 0, toolsAdded: context.messages[0].role === "system" ? context.messages[0].toolsAdded : [] },
    { role: "user", content: "First", timestamp: 1 },
    { role: "user", content: "Second", timestamp: 2 },
  ] }, () => undefined)).payload;
  expect(withSections.instructions).toBe("Base\n\nPolicy text");
  expect(withSections.tools).toContainEqual(expect.objectContaining({ name: "fixture_read" }));
  expect(withSections.input).toHaveLength(2);
  expect(payload.input.some((item: { type?: string }) => item.type === "additional_tools" || item.type === "configuration_update")).toBe(false);
  for (const field of legacy.request_constraints.responses.omit) expect(payload).not.toHaveProperty(field);
});

test("legacy Responses adapts streamed Codex terminal events for both Pi adapters", async () => {
  const legacy = {
    ...gatewayCatalog.data[0], id: "legacy/example",
    request_constraints: { responses: {
      ...entries[0].request_constraints!.responses, function_tools: "flat" as const, instructions: "Default instructions",
    } },
  };

  const [entry] = await parseCatalog(Response.json({ data: [legacy] }));
  const model = toPiModel(entry, "https://gateway.example.test/v1");
  const other = toPiModel(entries[0], "https://gateway.example.test/v1");
  const provider = createFumoProvider();
  const withoutSystem = normalizeContext({ messages: [{ role: "user", content: "Hello", timestamp: 1 }] });
  let calls = 0;
  let payload: unknown;
  function fixture(type: string) {
    const bytes = new TextEncoder().encode(`: comment\r\nevent: response.output_item.done\r\ndata: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg","role":"assistant","content":[{"type":"output_text","text":"héllo"}]}}\r\n\r\nevent: ${type}\r\ndata: {"type":"${type}",\r\ndata: "response":{"id":"fixture","status":"completed","output":[],"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}`);
    return new Response(new ReadableStream({
      start(controller) {
        for (let i = 0; i < bytes.length; i += 3) controller.enqueue(bytes.slice(i, i + 3));
        controller.close();
      },
    }), { headers: { "Content-Type": "text/event-stream; charset=utf-8" } });
  }
  let type = "response.done";
  const fetch = Object.assign(async () => { calls++; return fixture(type); }, { preconnect() {} });
  for (const method of ["stream", "streamSimple"] as const) {
    const result = await provider[method](model, withoutSystem, {
      apiKey: "fixture", fetch, onPayload(value) { payload = value; },
    }).result();
    expect(result.errorMessage).toBeUndefined();
    expect(result.stopReason).toBe("stop");
    expect(result.content).toContainEqual(expect.objectContaining({ type: "text", text: "héllo" }));
    expect(result.usage).toMatchObject({ input: 3, output: 2, totalTokens: 5 });
    expect(payload).toMatchObject({ instructions: "Default instructions" });
  }
  type = "response.completed";
  expect((await provider.streamSimple(model, withoutSystem, { apiKey: "fixture", fetch }).result()).stopReason).toBe("stop");
  type = "response.done";
  expect((await provider.streamSimple(other, withoutSystem, { apiKey: "fixture", fetch }).result()).stopReason).toBe("error");
  expect(calls).toBe(4);
});

test("legacy terminal events finish without waiting for upstream EOF", async () => {
  const legacy = {
    ...gatewayCatalog.data[0], id: "legacy/example",
    request_constraints: { responses: {
      ...entries[0].request_constraints!.responses, function_tools: "flat" as const, instructions: "Default instructions",
    } },
  };
  const [entry] = await parseCatalog(Response.json({ data: [legacy] }));
  const model = toPiModel(entry, "https://gateway.example.test/v1");
  const provider = createFumoProvider();
  const context = normalizeContext({ messages: [{ role: "user", content: "Hello", timestamp: 1 }] });

  for (const type of ["response.done", "response.completed", "response.incomplete"]) {
    let canceled = false;
    const source = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(`event: ${type}\ndata: ${JSON.stringify({
          type, response: { id: "fixture", status: "completed", end_turn: true, output: [], usage: { input_tokens: 3, output_tokens: 2, total_tokens: 5 } },
        })}\n\n`));
      },
      cancel() { canceled = true; },
    });
    const fetch = Object.assign(async () => new Response(source, { headers: { "Content-Type": "text/event-stream", "Content-Length": "123", "X-Fixture": "preserved" } }), { preconnect() {} });
    const events: unknown[] = [];
    let headers: Record<string, string> | undefined;
    const result = await Promise.race([
      provider.streamSimple(model, context, { apiKey: "fixture", fetch, onResponse: (response) => { headers = response.headers; }, onProviderStreamEvent: (event) => { events.push(event); } }).result(),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`Timed out after ${type}`)), 1000)),
    ]);
    expect(result.stopReason).toBe("stop");
    expect(events).toContainEqual(expect.objectContaining({ type: type === "response.done" ? "response.completed" : type, response: expect.objectContaining({ end_turn: true }) }));
    expect(result.endTurn).toBeUndefined();
    expect(headers).not.toHaveProperty("content-length");
    expect(headers?.["x-fixture"]).toBe("preserved");
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(canceled).toBe(true);
    expect(source.locked).toBe(false);
  }
});

test("compaction summarizes with the Sign in with ChatGPT model without unsupported cache options", async () => {
  const { runtime } = await discover();
  const requests: Request[] = [];
  spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: string | URL | Request, init?: RequestInit) => {
    const request = new Request(input, init);
    requests.push(request);
    const payload = await request.clone().json();
    if (payload.prompt_cache_options) {
      return Response.json({ error: {
        message: "prompt_cache_options is not supported on this model",
        type: "invalid_request_error", param: "prompt_cache_options", code: "invalid_parameter",
      } }, { status: 400 });
    }
    const events = [
      { type: "response.output_item.done", output_index: 0, item: {
        type: "message", id: "msg_summary", role: "assistant", content: [{ type: "output_text", text: "Fixture summary" }],
      } },
      { type: "response.completed", response: {
        id: "fixture-response", status: "completed", output: [], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
      } },
    ];
    return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
      headers: { "Content-Type": "text/event-stream" },
    });
  }, { preconnect() {} }));
  const summary = await generateSummary(
    [{ role: "user", content: "Keep this context", timestamp: 1 }],
    runtime.getModel("fumo", "personal/gpt-6.1-sol")!, undefined, undefined,
    undefined, undefined, undefined, undefined, "high", runtime.streamSimple.bind(runtime),
  );
  expect(summary).toBe("Fixture summary");
  expect(requests).toHaveLength(1);
  expect(requests[0].url).toBe("http://localhost:8080/v1/responses");
  const payload = await requests[0].json();
  expect(payload.model).toBe("personal/gpt-6.1-sol");
  expect(payload.prompt_cache_options).toBeUndefined();
  expect(payload.prompt_cache_retention).toBeUndefined();
  expect(payload.prompt_cache_key).toBeUndefined();
});

test("API-key codex namespace preserves native output/cache controls without inventing reasoning metadata", async () => {
  const { runtime } = await discover();
  const known = (await nativeRequest(runtime, "codex/gpt-6.1-sol")).payload;
  expect(known.max_output_tokens).toBe(100);
  expect(known.prompt_cache_options).toEqual({ ttl: "30m" });
  expect((await nativeRequest(runtime, "codex/gpt-6.1-sol", "none")).payload.prompt_cache_options).toEqual({ mode: "explicit" });
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
