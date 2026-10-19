const std = @import("std");
const alarm = @import("alarm.zig");

/// ntfy notification channel: one HTTP POST per alarm transition to
/// `<server>/<topic>` with the rendered alarm line as the raw body.
pub const Ntfy = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: []const u8,
    topic: []const u8,
    client: std.http.Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, server: []const u8, topic: []const u8) Ntfy {
        return .{
            .gpa = gpa,
            .io = io,
            .server = server,
            .topic = topic,
            .client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(t: *Ntfy) void {
        t.client.deinit();
    }

    pub const transport_vtable = alarm.Transport.VTable{
        .lastState = lastStateFn,
        .send = sendFn,
    };

    pub fn transport(t: *Ntfy) alarm.Transport {
        return .{ .ctx = t, .vtable = &transport_vtable };
    }

    fn lastStateFn(_: *anyopaque, _: []const u8) anyerror!?alarm.State {
        return error.NtfyNoHistory;
    }

    fn sendFn(ctx: *anyopaque, ev: alarm.AlarmEvent) anyerror!void {
        const t: *Ntfy = @ptrCast(@alignCast(ctx));
        var line_buf: [alarm.text_max]u8 = undefined;
        const body = try alarm.renderText(ev, &line_buf);

        var title_buf: [alarm.text_max]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "{s} {s}", .{
            if (ev.state == .down) "DOWN" else "UP",
            ev.check_id,
        });

        var url_buf: [512]u8 = undefined;
        const server = std.mem.trimEnd(u8, t.server, "/");
        const url = try std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ server, t.topic });

        const meta = headerValues(ev);
        const result = try t.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "X-Title", .value = title },
                .{ .name = "X-Priority", .value = meta.priority },
                .{ .name = "X-Tags", .value = meta.tags },
            },
        });
        if (result.status.class() != .success) return error.NtfyApi;
    }
};

/// ntfy metadata (level-4 "high" ping on DOWN, level-2 "low" on UP).
fn headerValues(ev: alarm.AlarmEvent) struct { priority: []const u8, tags: []const u8 } {
    return if (ev.state == .down)
        .{ .priority = "4", .tags = "warning" }
    else
        .{ .priority = "2", .tags = "white_check_mark" };
}

test "header values follow alarm state" {
    const down = headerValues(.{ .check_id = "web", .state = .down, .bucket = 7, .checker = "n", .kind = "http", .target = "h" });
    try std.testing.expectEqualStrings("4", down.priority);
    try std.testing.expectEqualStrings("warning", down.tags);
    const up = headerValues(.{ .check_id = "web", .state = .up, .bucket = 7, .checker = "n", .kind = "http", .target = "h" });
    try std.testing.expectEqualStrings("2", up.priority);
    try std.testing.expectEqualStrings("white_check_mark", up.tags);
}
