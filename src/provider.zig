const std = @import("std");

/// SIWC direct-token credentials are sent only to this approved endpoint.
pub const siwc_responses_url = "https://api.openai.com/v1/responses";

pub const Provider = struct {
    request_headers: []const []const u8,

    pub fn allowsRequestHeader(self: Provider, name: []const u8) bool {
        for (self.request_headers) |allowed| {
            if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
        }
        return false;
    }
};

// Current Responses forwarding contract, not a verified Codex integration.
// Verify the OpenAI/Codex entries against actual client/upstream requests when
// implementing that provider; keep its header requirements here, not in HTTP code.
pub const responses: Provider = .{
    .request_headers = &.{
        "accept", // Response format negotiation.
        "x-request-id", // Request correlation.
        "openai-beta", // OpenAI feature negotiation (provisional).
        "session_id", // Session identity (provisional).
        "conversation_id", // Conversation identity (provisional).
        "x-codex-turn-metadata", // Codex turn metadata (provisional).
        "x-codex-turn-state", // Codex turn state (provisional).
    },
};

test "Responses request header contract" {
    for ([_][]const u8{ "Accept", "X-Request-Id", "OpenAI-Beta", "Session_id", "Conversation_id", "X-Codex-Turn-Metadata", "X-Codex-Turn-State" }) |name| {
        try std.testing.expect(responses.allowsRequestHeader(name));
    }
    for ([_][]const u8{ "Authorization", "Proxy-Authorization", "Cookie", "X-Api-Key", "Api-Key", "Host", "Content-Length", "Connection", "X-Unrecognized" }) |name| {
        try std.testing.expect(!responses.allowsRequestHeader(name));
    }
}
