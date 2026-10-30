import { afterEach, expect, mock, spyOn, test } from "bun:test"
import { Connection, Credential, Model, Plugin, Provider } from "@opencode/plugin"
import type { ProviderEditor } from "@opencode/plugin/promise/provider"
import type { SessionHttpRequest } from "@opencode/plugin/promise/session"
import { Agent } from "@opencode/schema/agent"
import { Session } from "@opencode/schema/session"
import { LLMClient, LLMRequest, Message, ToolDefinition } from "@opencode/ai"
import { RequestExecutor } from "@opencode/ai/route/executor"
import { provider } from "@opencode/ai/providers/openai-compatible-responses"
import { OpenAICompatible } from "@opencode/ai/providers/openai-compatible"
import { Effect, Schema, Stream } from "effect"
import { HttpClientRequest, HttpClientResponse } from "effect/http"
import { parseCatalog } from "../../catalog"
import fixture from "../../../tests/fixtures/model-catalog.json"
import plugin, { createFumoPlugin, setupFumo, type FumoContext } from "./index"
import { toOpenCodeModel } from "./catalog"

const baseURL = "http://localhost:8080/v1"
const entries = await parseCatalog(Response.json(fixture))
const connection = {
  type: "credential", id: Credential.ID.make("cred_test"), label: "Test client", method: "key",
} satisfies Connection.Info
type NativeEvent = ReturnType<FumoContext["event"]["subscribe"]> extends AsyncIterable<infer E> ? E : never
const cleanups: Plugin.Cleanup[] = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup()
  mock.restore()
})

function events() {
  const queue: { event: NativeEvent; done: () => void }[] = []
  function idle() {}
  let wake: () => void = idle
  let aborted = false
  const subscribe: FumoContext["event"]["subscribe"] = async function* (options) {
    function abort() { aborted = true; wake() }
    options?.signal?.addEventListener("abort", abort, { once: true })
    try {
      while (!aborted) {
        if (!queue.length) await new Promise<void>((resolve) => { wake = resolve })
        const item = queue.shift()
        if (!item) continue
        yield item.event
        item.done()
      }
    } finally { options?.signal?.removeEventListener("abort", abort) }
  }
  return {
    subscribe,
    get aborted() { return aborted },
    send(integrationID: string) {
      return new Promise<void>((done) => {
        queue.push({ event: { id: "test", created: 1, type: "credential.switched", data: { integrationID, credentialID: null } }, done })
        wake()
      })
    },
  }
}

function harness(cached?: Schema.Json) {
  const stream = events()
  const values = new Map<string, Schema.Json>()
  if (cached) values.set("catalog", cached)
  let active: Connection.Info | undefined = connection
  let published: Parameters<ProviderEditor["add"]>[0] | undefined
  let transform: Parameters<FumoContext["provider"]["transform"]>[0] | undefined
  const registration = { dispose: async () => {} }

  function render() { transform?.({ add: (input) => { published = input } }); return published }
  const reload = mock(async () => { render() })
  const updateMethod = mock(async () => {})
  const hook = mock<FumoContext["session"]["hook"]>(async () => registration)

  const context: FumoContext = {
    options: { baseURL: `${baseURL}/` },
    integration: {
      transform: async (callback) => {
        callback({ update: (id, update) => { update({ id, name: id }) }, method: { update: updateMethod } })
        return registration
      },
      connection: {
        active: async (id) => { expect(id).toBe("fumo"); return active },
        resolve: async () => ({ type: "key", key: "test-client-key" }),
      },
    },
    provider: { transform: async (callback) => { transform = callback; return registration }, reload },
    storage: { get: async (key) => values.get(key), set: async (key, value) => { values.set(key, value) } },
    event: { subscribe: stream.subscribe },
    session: { hook },
  }
  return {
    context, values, stream, reload, render, hook, updateMethod,
    disconnect() { active = undefined },
    switchAccount() { active = { ...connection, id: Credential.ID.make("cred_second") }; return active },
    async start() { const cleanup = await setupFumo(context); cleanups.push(cleanup); return cleanup },
  }
}

function network() {
  return spyOn(globalThis, "fetch").mockImplementation(Object.assign(
    async (url: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      expect(url).toBe(`${baseURL}/models`)
      expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer test-client-key")
      return Response.json(fixture)
    }, { preconnect: globalThis.fetch.preconnect },
  ))
}

test("native options, key integration, account-scoped cache, filtered refresh events, and cancellation", async () => {
  expect(plugin.id).toBe("fumo")
  expect(createFumoPlugin({ baseURL }).id).toBe("fumo")
  const fetch = network()
  const host = harness()
  const cleanup = await host.start()
  expect(host.updateMethod).toHaveBeenCalledWith({ integrationID: "fumo", method: { type: "key", label: "Fumo client API key" } })
  expect(host.render()?.info.settings).toEqual({ baseURL, transport: "http" })
  expect(host.render()?.sourceConnection).toEqual(connection)
  expect(host.render()?.models.map((model) => String(model.id))).toEqual(entries.map((entry) => entry.id))
  await host.stream.send("openai")
  expect(fetch).toHaveBeenCalledTimes(1)
  const switched = host.switchAccount()
  await host.stream.send("fumo")
  expect(host.render()?.sourceConnection).toEqual(switched)
  expect(fetch).toHaveBeenCalledTimes(2)
  expect(JSON.stringify(host.values.get("catalog"))).not.toContain("test-client-key")

  const cached = harness(host.values.get("catalog"))
  cached.disconnect()
  await cached.start()
  expect(fetch).toHaveBeenCalledTimes(2)
  expect(cached.render()?.sourceConnection).toEqual(switched)
  expect(cached.render()?.models).toEqual(host.render()?.models)
  const signal = fetch.mock.calls[0]?.[1]?.signal
  await cleanup()
  expect(signal?.aborted).toBe(true)
  expect(host.stream.aborted).toBe(true)
})

test("failed or malformed discovery retains the last successful account-bound inventory", async () => {
  const fetch = network()
  const host = harness()
  await host.start()
  const saved = host.values.get("catalog")
  const warning = spyOn(console, "warn").mockImplementation(() => {})
  host.switchAccount()
  for (const response of [Response.json({}, { status: 503 }), Response.json({ data: [{ id: 42 }] })]) {
    fetch.mockResolvedValue(response)
    await host.stream.send("fumo")
    expect(host.values.get("catalog")).toEqual(saved)
    expect(host.render()?.sourceConnection).toEqual(connection)
  }
  expect(host.reload).toHaveBeenCalledTimes(1)
  expect(warning).toHaveBeenCalledTimes(2)
})

test("native projection uses only discovered metadata and native defaults, not OpenAI templates", () => {
  for (const entry of entries) {
    const model = toOpenCodeModel(entry)
    expect(String(model.id)).toBe(entry.id)
    expect(model.headers).toBeUndefined()
    expect(model.family).toBeUndefined()
    expect(model.compatibility).toBeUndefined()
  }
  const personal = entries.find((entry) => entry.id === "personal/fast")
  if (!personal) throw new Error("Missing personal fixture entry")
  expect(toOpenCodeModel(personal)).toMatchObject({
    name: "Personal Codex", limit: { context: 272000, output: 16000 },
    capabilities: { input: ["text", "image"] },
    variants: [{ id: "low", body: { reasoning: { effort: "low" } } }, { id: "high", body: { reasoning: { effort: "high" } } }],
  })
  const sparse = entries.find((entry) => entry.id === "personal/future")
  if (!sparse) throw new Error("Missing sparse fixture entry")
  const defaults = Model.Info.default(Provider.ID.make("fumo"), Model.ID.make(sparse.id))
  expect(toOpenCodeModel(sparse)).toMatchObject({ limit: defaults.limit, capabilities: defaults.capabilities, variants: [] })
})

async function nativeRequest(entry: typeof entries[number]) {
  const completions = entry.api === "openai-completions"
  const configure = completions ? OpenAICompatible.configure : provider.configure
  const model = configure({
    baseURL, apiKey: "test-client-key",
    http: { body: { prompt_cache_retention: "24h", previous_response_id: "resp_old" } },
  }).model(entry.id)
  const request = new LLMRequest({
    model, system: [{ type: "text", text: "Be helpful" }],
    messages: [Message.system("Updated instructions"), Message.user("Hello")],
    tools: [new ToolDefinition({ name: "read", description: "Read a file", inputSchema: { type: "object", properties: {} } })],
    generation: { maxTokens: 4096, temperature: 0.7, topP: 0.9 },
    providerOptions: { metadata: { test: "value" }, maxToolCalls: 2, topLogprobs: 3, truncation: "auto", reasoningEffort: "high" },
    promptCacheKey: "session-cache",
  })
  let outgoing: Request | undefined
  await Effect.runPromise(LLMClient.stream(request).pipe(
    Stream.runDrain,
    Effect.provide(LLMClient.layer),
    Effect.provideService(RequestExecutor.Service, {
      execute: (native) => Effect.gen(function* () {
        outgoing = yield* HttpClientRequest.toWeb(native).pipe(Effect.orDie)
        return HttpClientResponse.fromWeb(native, new Response(completions
          ? 'data: {"id":"chat_test","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
          : 'data: {"type":"response.completed","response":{"id":"resp_test","output":[]}}\n\n',
        { headers: { "Content-Type": "text/event-stream" } }))
      }),
    }),
  ))
  if (!outgoing) throw new Error("Native transport did not send a request")
  return outgoing
}

test("actual native Responses and Completions wire requests follow advertised constraints, not namespaces", async () => {
  network()
  const host = harness()
  await host.start()
  const hook = host.hook.mock.calls[0]
  if (!hook) throw new Error("Missing HTTP hook")
  const [name, callback, options] = hook
  expect(name).toBe("http.request")
  expect(options?.providerID).toBe("fumo")
  for (const entry of entries) {
    const outgoing = await nativeRequest(entry)
    const before = await outgoing.clone().json()
    const completions = entry.api === "openai-completions"
    expect(outgoing.url).toBe(`${baseURL}/${completions ? "chat/completions" : "responses"}`)
    expect(before).toMatchObject({ model: entry.id, stream: true, temperature: 0.7, top_p: 0.9 })
    expect(before[completions ? "max_completion_tokens" : "max_output_tokens"]).toBe(4096)
    const input: SessionHttpRequest = {
      sessionID: Session.ID.create(), agent: Agent.ID.make("test"), kind: "primary",
      model: { providerID: Provider.ID.make("fumo"), id: Model.ID.make(entry.id) }, request: outgoing,
    }
    await callback(input)
    expect(input.request.headers.get("Authorization")).toBe("Bearer test-client-key")
    const body = await input.request.json()
    expect(body.model).toBe(entry.id)
    const constraints = entry.request_constraints?.responses
    if (constraints && !completions) {
      for (const field of constraints.omit) expect(body).not.toHaveProperty(field)
      expect(body).toMatchObject({ stream: true, store: false, reasoning: { effort: "high" }, prompt_cache_key: "session-cache" })
      expect(body.input[0]).toEqual({ type: "additional_tools", role: "developer", tools: before.tools })
      expect(body.input.slice(1)).toEqual(before.input)
      expect(before.input[0]).toMatchObject({ role: "developer", content: "Updated instructions" })
    } else {
      expect(input.request).toBe(outgoing)
      expect(body).toEqual(before)
    }
  }
})
