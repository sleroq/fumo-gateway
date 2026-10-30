import { Schema } from "effect"
import type { ResponsesConstraints } from "../../catalog.js"

const JsonObject = Schema.Record(Schema.String, Schema.Json)
const FunctionTool = Schema.StructWithRest(Schema.Struct({ type: Schema.Literals(["function", "custom"]) }), [JsonObject])

// Native OpenCode supplies array input and developer messages. Only adapt the
// omissions and flat tool format its compatible Responses adapter cannot express.
export async function constrainResponses(request: Request, constraints: ResponsesConstraints): Promise<Request> {
  const body = { ...Schema.decodeUnknownSync(JsonObject)(await request.json()) }
  for (const field of constraints.omit) delete body[field]
  if (Array.isArray(body.tools) && Array.isArray(body.input)) {
    const functions = body.tools.filter(Schema.is(FunctionTool))
    if (functions.length) {
      body.input = [{ type: "additional_tools", role: "developer", tools: functions }, ...body.input]
      body.tools = body.tools.filter((tool) => !functions.includes(tool))
    }
  }
  return new Request(request, { body: JSON.stringify(body) })
}
