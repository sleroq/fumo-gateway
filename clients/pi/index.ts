import { createProvider, envApiKeyAuth, getInitialSystemMessage, getSystemMessageText, resolveTranscript, type Model, type ProviderStreams, type RefreshModelsContext, type ThinkingLevelMap } from "@earendil-works/pi-ai";
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
    if (metadata.constraints.function_tools === "flat" && metadata.constraints.instructions !== undefined) compat.supportsStrictMode ??= true;
    if (metadata.constraints.omit.includes("max_output_tokens")) compat.supportsMaxOutputTokens = false;
    if (metadata.constraints.omit.includes("prompt_cache_options")) compat.supportsExplicitPromptCacheMode = false;
    if (metadata.constraints.omit.includes("prompt_cache_retention")) compat.supportsLongCacheRetention = false;
    // Pi needs both flags to place function tools in native additional_tools items.
    compat.supportsAdditionalTools = metadata.constraints.function_tools === "namespaced-or-additional";
    compat.supportsMidConvoSystemMessages = metadata.constraints.function_tools === "namespaced-or-additional";
    // SIWC rejects configuration_update input items even when the native model supports them.
    compat.supportsMidConvoEffort = false;
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
    ...(metadata.constraints?.instructions !== undefined && { samplingParams: { instructions: metadata.constraints.instructions } }),
    ...(metadata.constraints?.function_tools === "flat" && metadata.constraints.instructions !== undefined && {
      headers: { Accept: "text/event-stream", originator: "pi" },
    }),
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

type ResponsesModel = Parameters<ProviderStreams["stream"]>[0];
type ResponsesContext = Parameters<ProviderStreams["stream"]>[1];
type ResponsesOptions = Parameters<ProviderStreams["stream"]>[2];

// Sampling parameters can replace any of these native adapter fields.
type LegacyResponsesPayload = {
  instructions?: unknown;
  text?: unknown;
  tool_choice?: unknown;
  parallel_tool_calls?: unknown;
  tools?: unknown;
};

function prepareLegacyResponses(model: ResponsesModel, context: ResponsesContext) {
  if (model.api !== "openai-responses") return undefined;
  // SAFETY: the API discriminator above identifies Responses compatibility metadata.
  const compat = (model as Model<"openai-responses">).compat;
  if (compat?.supportsAdditionalTools !== false || compat.supportsMidConvoSystemMessages !== false ||
      typeof model.samplingParams?.instructions !== "string") return undefined;

  const resolved = resolveTranscript(context, false);
  const system = getInitialSystemMessage(resolved.messages);
  return {
    instructions: system ? getSystemMessageText(system) || model.samplingParams.instructions : model.samplingParams.instructions,
    context: system ? { ...resolved, messages: [{ ...system, content: "", sections: undefined }, ...resolved.messages.slice(1)] } : resolved,
  };
}

function legacyPayload(payload: LegacyResponsesPayload, instructions: string, options: ResponsesOptions, model: ResponsesModel) {
  const verbosity = options && "textVerbosity" in options && typeof options.textVerbosity === "string" ? options.textVerbosity : "low";
  const text = payload.text;
  const updated = {
    ...payload,
    instructions: options?.samplingParams?.instructions ?? instructions,
    text: text === undefined || (typeof text === "object" && text !== null)
      ? { verbosity: verbosity || "low", ...text }
      : text,
    tool_choice: payload.tool_choice === undefined ? "auto" : payload.tool_choice,
    parallel_tool_calls: payload.parallel_tool_calls === undefined ? true : payload.parallel_tool_calls,
  };
  if (options?.samplingParams?.tools === undefined && model.samplingParams?.tools === undefined && Array.isArray(updated.tools)) {
    const tools: unknown[] = updated.tools;
    updated.tools = tools.map((tool) =>
      tool && typeof tool === "object" && "type" in tool && tool.type === "function" && "strict" in tool && tool.strict === false
        ? { ...tool, strict: null } : tool);
  }
  return updated;
}

function completedEvent(lines: string[]) {
  const data = lines.flatMap((line) => {
    const match = /^data(?:: ?(.*))?$/.exec(line.replace(/[\r\n]+$/, ""));
    return match ? [match[1] ?? ""] : [];
  }).join("\n");
  let event: unknown;
  try { event = JSON.parse(data); } catch { return { text: lines.join(""), terminal: false }; }
  if (!event || typeof event !== "object" || !("type" in event)) return { text: lines.join(""), terminal: false };
  if (event.type !== "response.done") return {
    text: lines.join(""), terminal: event.type === "response.completed" || event.type === "response.incomplete",
  };

  let written = false;
  const text = lines.map((line) => {
    const match = /^(data|event)(?:: ?([^\r\n]*))?([\r\n]*)$/.exec(line);
    if (!match) return line;
    if (match[1] === "event") return match[2] === "response.done" ? `event: response.completed${match[3]}` : line;
    if (written) return "";
    written = true;
    return `data: ${JSON.stringify({ ...event, type: "response.completed" })}${match[3]}`;
  }).join("");
  return { text, terminal: true };
}

async function legacyFetch(fetcher: typeof fetch, ...args: Parameters<typeof fetch>): Promise<Response> {
  const response = await fetcher(...args);
  if (!response.ok || !response.body || !/^text\/event-stream(?:\s*;|\s*$)/i.test(response.headers.get("content-type") ?? "")) return response;

  let pending = "";
  let lines: string[] = [];
  const body = response.body.pipeThrough(new TextDecoderStream()).pipeThrough(new TransformStream<string, string>({
    transform(chunk, controller) {
      pending += chunk;
      let end: number;
      while ((end = pending.search(/[\r\n]/)) !== -1) {
        if (pending[end] === "\r" && end === pending.length - 1) break;
        const length = pending[end] === "\r" && pending[end + 1] === "\n" ? 2 : 1;
        const line = pending.slice(0, end + length);
        pending = pending.slice(end + length);
        if (end === 0) {
          const event = completedEvent(lines);
          controller.enqueue(event.text + line);
          lines = [];
          if (event.terminal) {
            controller.terminate();
            return;
          }
        } else lines.push(line);
      }
    },
    flush(controller) {
      if (pending) lines.push(pending);
      if (lines.length) controller.enqueue(completedEvent(lines).text);
    },
  })).pipeThrough(new TextEncoderStream());
  const headers = new Headers(response.headers);
  headers.delete("content-length");
  return new Response(body, { status: response.status, statusText: response.statusText, headers });
}

function legacyOptions(instructions: string, model: ResponsesModel, options: ResponsesOptions): ResponsesOptions {
  return { ...options, fetch: Object.assign((input: RequestInfo | URL, init?: RequestInit) => legacyFetch(options?.fetch ?? globalThis.fetch, input, init), { preconnect: globalThis.fetch.preconnect }), onPayload: async (payload, payloadModel) => {
    // SAFETY: the native Responses adapter invokes this hook with its request object; sampling overrides remain unknown until inspected.
    const updated = legacyPayload(payload as LegacyResponsesPayload, instructions, options, model);
    const result = await options?.onPayload?.(updated, payloadModel);
    return result === undefined ? updated : result;
  } };
}

function responsesApi(): ProviderStreams {
  const api = openAIResponsesApi();
  return {
    stream(model, context, options) {
      const prepared = prepareLegacyResponses(model, context);
      return prepared ? api.stream(model, prepared.context, legacyOptions(prepared.instructions, model, options)) : api.stream(model, context, options);
    },
    streamSimple(model, context, options) {
      const prepared = prepareLegacyResponses(model, context);
      return prepared ? api.streamSimple(model, prepared.context, legacyOptions(prepared.instructions, model, options)) : api.streamSimple(model, context, options);
    },
  };
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
      "openai-responses": responsesApi(),
      "openai-completions": openAICompletionsApi(),
    },
  });
}

export default function (pi: Pick<ExtensionAPI, "registerProvider">) {
  pi.registerProvider(createFumoProvider({ baseUrl: process.env.FUMO_BASE_URL }));
}
