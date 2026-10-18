const std = @import("std");
const alarm = @import("alarm.zig");

/// Real Telegram transport: one bot token, one chat. The chat is the alarm
/// notification surface only (a smoke test showed the bot never sees its own
/// sendMessage output in getUpdates, so chat history can't store alarm state —
/// see ADR 0001/0002); state lives in alarm.FileTransport.
pub const Telegram = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    chat_id: i64,
    /// Bot API base; overridable for test mocks and self-hosted bridges.
    api_base: []const u8 = "https://api.telegram.org",
    client: std.http.Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, token: []const u8, chat_id: i64) Telegram {
        return .{
            .gpa = gpa,
            .io = io,
            .token = token,
            .chat_id = chat_id,
            .client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn transport(t: *Telegram) alarm.Transport {
        return .{ .ctx = t, .vtable = &vtable };
    }

    const vtable = alarm.Transport.VTable{
        .lastState = lastStateFn,
        .send = sendFn,
    };

    fn lastStateFn(_: *anyopaque, _: []const u8) anyerror!?alarm.State {
        return error.TelegramNoHistory;
    }

    /// GET the Bot API method with raw query params already urlencoded.
    fn fetchBody(t: *Telegram, url: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(t.gpa);
        defer out.deinit();
        const res = try t.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &out.writer,
        });
        if (res.status.class() != .success) return error.HttpFailure;
        return try out.toOwnedSlice();
    }

    /// Build "<api_base>/bot<token>/<method>[?query]"; returns a slice of buf.
    /// Use raw query strings only; values must already be encoded.
    fn apiUrl(t: *Telegram, method: []const u8, query: []const u8, buf: []u8) ![]const u8 {
        if (query.len == 0)
            return try std.fmt.bufPrint(buf, "{s}/bot{s}/{s}", .{ t.api_base, t.token, method });
        return try std.fmt.bufPrint(buf, "{s}/bot{s}/{s}?{s}", .{ t.api_base, t.token, method, query });
    }

    fn sendFn(ctx: *anyopaque, text: []const u8) anyerror!void {
        const t: *Telegram = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("chat_id={d}&text=", .{t.chat_id});
        try encodeQuery(&w, text);
        const body = try t.fetchBody(try t.apiUrl("sendMessage", w.buffered(), &url_buf));
        defer t.gpa.free(body);
        if (!(try apiOk(t.gpa, body))) return error.TelegramApi;
    }
};

var url_buf: [512]u8 = undefined;

/// Telegram only trusts its own api domain; check ids are hostnames/targets,
/// so this minimal encoder (unreserved pass-through) is all a chat_id/text needs.
fn encodeQuery(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// Bot API wraps errors in HTTP 200 with ok:false, so every response body
/// must be checked, not just the status.
pub fn apiOk(gpa: std.mem.Allocator, body: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const ok = parsed.value.object.get("ok") orelse return false;
    return ok.bool;
}

const tele = @import("telegram_test_data.zig");

test "apiOk reads ok field" {
    try std.testing.expect(try apiOk(std.testing.allocator, tele.ok_true));
    try std.testing.expect(!try apiOk(std.testing.allocator, tele.ok_false));
}

test "encodeQuery percent-encodes non-unreserved" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try encodeQuery(&w, "a b&c:xyz");
    try std.testing.expectEqualStrings("a%20b%26c%3Axyz", w.buffered());
}
