import { Type, type Static, type TSchema } from "typebox";
import { Value } from "typebox/value";

function optional<T extends TSchema>(schema: T) {
  return Type.Optional(Type.Union([schema, Type.Null()]));
}
const number = optional(Type.Number());
const modalities = optional(Type.Array(Type.String()));
export const ResponsesConstraints = Type.Object({
  omit: Type.Array(Type.String()),
  function_tools: Type.Literal("namespaced-or-additional"),
  unsupported_tools: Type.Array(Type.String()),
});
export type ResponsesConstraints = Static<typeof ResponsesConstraints>;

export const CatalogEntry = Type.Object({
  id: Type.String({ pattern: "^[A-Za-z0-9_-]+/.+$" }),
  api: Type.Optional(Type.Union([Type.Literal("openai-responses"), Type.Literal("openai-completions")])),
  name: optional(Type.String()),
  context_window: number,
  context_length: number,
  max_output_tokens: number,
  input_modalities: modalities,
  architecture: optional(Type.Object({ input_modalities: modalities })),
  top_provider: optional(Type.Object({ max_completion_tokens: number })),
  supported_reasoning_levels: optional(Type.Array(Type.Object({ effort: Type.String() }))),
  request_constraints: Type.Optional(Type.Object({ responses: ResponsesConstraints })),
});
export type CatalogEntry = Static<typeof CatalogEntry>;
const Catalog = Type.Object({ data: Type.Array(CatalogEntry) });

export async function parseCatalog(response: Response): Promise<CatalogEntry[]> {
  const body: unknown = await response.json();
  if (!Value.Check(Catalog, body)) throw new Error("fumo returned an invalid model catalog.");
  return body.data.filter((entry) => !nativeModelId(entry.id).startsWith("gpt-image-"));
}

export function nativeModelId(id: string) {
  return id.slice(id.indexOf("/") + 1);
}

// Interpret upstream field alternatives once; absent capabilities stay absent.
export function modelMetadata(entry: CatalogEntry) {
  const api = entry.api ?? "openai-responses";
  return {
    id: entry.id,
    api,
    name: entry.name ?? entry.id,
    context: entry.context_window ?? entry.context_length ?? undefined,
    output: entry.max_output_tokens ?? entry.top_provider?.max_completion_tokens ?? undefined,
    input: entry.input_modalities ?? entry.architecture?.input_modalities ?? undefined,
    efforts: entry.supported_reasoning_levels?.map(({ effort }) => effort),
    constraints: api === "openai-responses" ? entry.request_constraints?.responses : undefined,
  };
}

export async function discoverModels(baseUrl: string, key: string, signal: AbortSignal) {
  const response = await fetch(`${baseUrl}/models`, {
    headers: { Authorization: `Bearer ${key}` },
    signal: AbortSignal.any([signal, AbortSignal.timeout(15000)]),
  });
  if (!response.ok) throw new Error(`fumo model discovery failed (HTTP ${response.status}).`);
  return parseCatalog(response);
}
