import { createProvider, envApiKeyAuth, type Model, type RefreshModelsContext, type ThinkingLevelMap } from "@earendil-works/pi-ai";
// Pi 1.4's extension loader does not resolve the public api/* subpaths.
import { openAICompletionsApi, openAIResponsesApi } from "@earendil-works/pi-ai/compat";
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { discoverModels, modelMetadata, nativeModelId, type CatalogEntry } from "../catalog.js";

const catalog = getBuiltinModels("openai");

export interface FumoProviderOptions {
  /** Gateway API root, including /v1, without a trailing slash. */
  baseUrl?: string;
}

function thinkingLevelMap(efforts: string[]): ThinkingLevelMap {
  const map: ThinkingLevelMap = { off: efforts.includes("none") ? "none" : null };
  for (const level of ["minimal", "low", "medium", "high", "xhigh", "max"] as const) {
    map[level] = efforts.includes(level) ? level : null;
  }
  return map;
}

export function toPiModel(entry: CatalogEntry, baseUrl: string): Model<"openai-responses" | "openai-completions"> {
  const metadata = modelMetadata(entry);
  const known = catalog.find(({ id }) => id === nativeModelId(entry.id));

  // Only native model capabilities: discovery owns all metadata and route policy.
  const compat: Model<"openai-responses">["compat"] = metadata.api === "openai-responses" ? {
    supportsStrictMode: known?.compat?.supportsStrictMode,
    supportsOpenAIGrammarTools: known?.compat?.supportsOpenAIGrammarTools,
    supportsAdditionalTools: known?.compat?.supportsAdditionalTools,
    supportsToolSearch: known?.compat?.supportsToolSearch,
    supportsMidConvoSystemMessages: known?.compat?.supportsMidConvoSystemMessages,
    supportsExplicitPromptCacheMode: known?.compat?.supportsExplicitPromptCacheMode,
    supportsMidConvoEffort: known?.compat?.supportsMidConvoEffort,
  } : undefined;

  if (metadata.constraints && compat) {
    if (metadata.constraints.omit.includes("max_output_tokens")) compat.supportsMaxOutputTokens = false;
    if (metadata.constraints.omit.includes("prompt_cache_retention")) compat.supportsLongCacheRetention = false;
    // Pi needs both flags to place function tools in native additional_tools items.
    compat.supportsAdditionalTools = true;
    compat.supportsMidConvoSystemMessages = true;
    if (metadata.constraints.unsupported_tools.includes("tool_search")) compat.supportsToolSearch = false;
  }

  return {
    id: metadata.id,
    name: metadata.name,
    provider: "fumo",
    api: metadata.api,
    baseUrl,
    reasoning: metadata.efforts?.some((effort) => effort !== "none") ?? false,
    thinkingLevelMap: metadata.efforts ? thinkingLevelMap(metadata.efforts) : undefined,
    input: metadata.input?.filter((modality) => modality === "text" || modality === "image") ?? ["text"],
    contextWindow: metadata.context ?? 128000,
    maxTokens: metadata.output ?? 16384,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    compat,
  };
}

async function fetchModels(context: RefreshModelsContext, baseUrl: string) {
  const credential = context.credential?.type === "api_key" ? context.credential : undefined;
  const key = credential?.key;
  if (!key) throw new Error("Run /login fumo before refreshing models.");
  baseUrl = credential?.env?.FUMO_BASE_URL ?? baseUrl;
  const entries = await discoverModels(baseUrl, key, context.signal);
  return entries.map((entry) => toPiModel(entry, baseUrl));
}

export function createFumoProvider({ baseUrl = "http://localhost:8080/v1" }: FumoProviderOptions = {}) {
  const apiKey = envApiKeyAuth("Fumo client API key", ["FUMO_PI_KEY"]);
  return createProvider({
    id: "fumo",
    name: "Fumo gateway",
    baseUrl,
    auth: { apiKey: {
      ...apiKey,
      async login(interaction) {
        interaction.signal.throwIfAborted();
        const input = await interaction.prompt({
          type: "text", message: "Gateway URL (including /v1)", placeholder: baseUrl,
        });
        const url = new URL(input.trim() || baseUrl);
        if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("Gateway URL must use HTTP or HTTPS.");
        const key = await interaction.prompt({ type: "secret", message: "Enter Fumo client API key" });
        interaction.signal.throwIfAborted();
        return { type: "api_key", key, env: { FUMO_BASE_URL: url.href.replace(/\/+$/, "") } };
      },
      async resolve(input) {
        const result = await apiKey.resolve(input);
        if (!result) return undefined;
        const url = result.env?.FUMO_BASE_URL ?? baseUrl;
        return { ...result, auth: { ...result.auth, baseUrl: url }, env: { ...result.env, FUMO_BASE_URL: url } };
      },
    } },
    models: [],
    fetchModels: (context) => fetchModels(context, baseUrl),
    api: {
      "openai-responses": openAIResponsesApi(),
      "openai-completions": openAICompletionsApi(),
    },
  });
}

export default function (pi: Pick<ExtensionAPI, "registerProvider">) {
  pi.registerProvider(createFumoProvider({ baseUrl: process.env.FUMO_BASE_URL }));
}
