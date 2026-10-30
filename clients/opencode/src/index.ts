import { Plugin, Provider } from "@opencode/plugin"
import type { IntegrationEditor } from "@opencode/plugin/promise/integration"
import type { SessionHttpRequest } from "@opencode/plugin/promise/session"
import type { ModelHookOptions } from "@opencode/plugin/promise/registration"
import { Schema } from "effect"
import { createCatalog, type CatalogContext } from "./catalog.js"
import { constrainResponses } from "./responses.js"

export type FumoContext = CatalogContext & {
  options: Plugin.Context["options"]
  integration: {
    transform: (callback: (editor: Pick<IntegrationEditor, "update"> & {
      method: Pick<IntegrationEditor["method"], "update">
    }) => void) => Promise<unknown>
  }
  session: {
    hook: (name: "http.request", callback: (input: SessionHttpRequest) => Promise<void>, options?: ModelHookOptions) => Promise<unknown>
  }
  event: Pick<Plugin.Context["event"], "subscribe">
}
const Options = Schema.Struct({ baseURL: Schema.optionalKey(Schema.String) })

export function createFumoPlugin(options: { baseURL?: string } = {}) {
  return Plugin.define({ id: "fumo", setup: (ctx) => setupFumo(ctx, options.baseURL) })
}

export async function setupFumo(ctx: FumoContext, endpoint?: string) {
  const options = Schema.decodeUnknownSync(Options)(ctx.options)
  const baseURL = (endpoint ?? options.baseURL ?? "http://localhost:8080/v1").replace(/\/+$/, "")
  const provider = {
    ...Provider.Info.empty(Provider.ID.make("fumo")),
    name: "Fumo Gateway",
    package: "@opencode/ai/providers/openai",
    settings: { baseURL, transport: "http" },
  } satisfies Provider.Info
  await ctx.integration.transform((editor) => {
    editor.update(provider.id, (integration) => { integration.name = provider.name })
    editor.method.update({ integrationID: provider.id, method: { type: "key", label: "Fumo client API key" } })
  })

  const controller = new AbortController()
  const catalog = await createCatalog(ctx, provider, baseURL, controller.signal)
  await ctx.session.hook("http.request", async (input) => {
    if (!new URL(input.request.url).pathname.endsWith("/responses")) return
    const constraints = catalog.responsesConstraints(input.model.id)
    if (constraints) input.request = await constrainResponses(input.request, constraints)
  }, { providerID: provider.id })
  function refreshInBackground() {
    return catalog.refresh().catch((error) => console.warn("fumo model discovery failed; restart OpenCode to retry", error))
  }
  const watching = (async () => {
    for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
      if (event.type === "credential.switched" && event.data.integrationID === provider.id) await refreshInBackground()
    }
  })().catch(() => {
    if (!controller.signal.aborted) console.warn("fumo credential subscription failed; restart OpenCode")
  })
  await refreshInBackground()
  return async () => {
    controller.abort()
    await watching
  }
}

export default createFumoPlugin()
