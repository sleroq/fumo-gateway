import { Connection, Model, Plugin, Provider } from "@opencode/plugin"
import type { ProviderEditor } from "@opencode/plugin/promise/provider"
import { Schema } from "effect"
import { Type } from "typebox"
import { Value } from "typebox/value"
import { CatalogEntry, discoverModels, modelMetadata } from "../../catalog.js"

export type CatalogContext = {
  integration: { connection: Pick<Plugin.Context["integration"]["connection"], "active" | "resolve"> }
  provider: {
    transform: (callback: (editor: Pick<ProviderEditor, "add">) => void) => Promise<unknown>
    reload: Plugin.Context["provider"]["reload"]
  }
  storage: Pick<Plugin.Context["storage"], "get" | "set">
}
const Cached = Type.Object({ connection: Type.Unknown(), models: Type.Array(CatalogEntry) })

export function toOpenCodeModel(entry: CatalogEntry): Model.Info {
  const metadata = modelMetadata(entry)
  const defaults = Model.Info.default(Provider.ID.make("fumo"), Model.ID.make(metadata.id))
  return {
    ...defaults,
    name: metadata.name,
    package: metadata.api === "openai-completions"
      ? "@opencode/ai/providers/openai-compatible"
      : "@opencode/ai/providers/openai-compatible-responses",
    capabilities: { ...defaults.capabilities, input: metadata.input ?? defaults.capabilities.input },
    limit: { context: metadata.context ?? defaults.limit.context, output: metadata.output ?? defaults.limit.output },
    variants: metadata.efforts?.map((effort) => ({
      id: Model.VariantID.make(effort),
      body: metadata.api === "openai-completions" ? { reasoning_effort: effort } : { reasoning: { effort } },
    })) ?? defaults.variants,
  }
}

export async function createCatalog(ctx: CatalogContext, provider: Provider.Info, baseURL: string, signal: AbortSignal) {
  const cached = await ctx.storage.get("catalog")
  let inventory = Value.Check(Cached, cached) && Schema.is(Connection.Info)(cached.connection)
    ? { connection: cached.connection, models: cached.models }
    : undefined
  await ctx.provider.transform((editor) => {
    editor.add({
      info: provider,
      models: inventory?.models.map(toOpenCodeModel) ?? [],
      sourceConnection: inventory?.connection,
    })
  })

  return {
    responsesConstraints(id: string) {
      const entry = inventory?.models.find((entry) => entry.id === id)
      return entry && modelMetadata(entry).constraints
    },
    async refresh() {
      const connection = await ctx.integration.connection.active(provider.id)
      if (!connection) return
      const credential = await ctx.integration.connection.resolve(connection)
      if (credential?.type !== "key") throw new Error("fumo requires a client API key. Use /connect.")
      const models = await discoverModels(baseURL, credential.key, signal)
      const catalog = { connection: Schema.decodeUnknownSync(Connection.Info)(connection), models }
      await ctx.storage.set("catalog", catalog)
      inventory = catalog
      await ctx.provider.reload()
    },
  }
}
