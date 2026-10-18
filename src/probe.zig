const std = @import("std");

/// Result of a probe: ok means "target healthy", fail opens (or closes) an alarm.
pub const Result = enum(u8) {
    fail,
    ok,
};

pub const TIMEOUT_SECS: u64 = 5;

fn timeoutDuration() std.Io.Timeout {
    return .{ .duration = std.Io.Duration.fromSeconds(TIMEOUT_SECS) };
}

/// GET; ok iff the status code equals `expect` (spec: "compare status code").
/// Network/TLS/DNS failure is fail.
pub fn httpProbe(io: std.Io, url: []const u8, expect: u16) Result {
    var client: std.http.Client = .{
        .allocator = std.heap.page_allocator,
        .io = io,
    };
    defer client.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
    }) catch return .fail;
    return if (@as(u16, @truncate(@intFromEnum(res.status))) == expect) .ok else .fail;
}

pub fn tcpProbe(io: std.Io, host: []const u8, port: u16) Result {
    const addr = std.Io.net.IpAddress.resolve(io, host, port) catch return .fail;
    var stream = addr.connect(io, .{
        .mode = .stream,
    }) catch return .fail;
    defer stream.close(io);
    return .ok;
}

pub fn pingProbe(gpa: std.mem.Allocator, io: std.Io, target: []const u8) Result {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "ping", "-c", "1", "-W", "5", target },
    }) catch return .fail;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const ok = res.term == .exited and res.term.exited == 0 and res.stdout.len > 0;
    return if (ok) .ok else .fail;
}

const testing = std.testing;

fn findOpenPort(io: std.Io, base: u16) u16 {
    var port = base;
    while (port < base + 200) : (port += 1) {
        const guess = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        var probe_srv = guess.listen(io, .{}) catch continue;
        probe_srv.deinit(io);
        return port;
    }
    unreachable;
}

const http_responses = 4;

/// Serves connections until `total_connections` have been handled, then returns.
/// Never waits on the listener being closed, so the test can join it promptly.
fn srvRun(io: std.Io, srv: *std.Io.net.Server) void {
    var connections: usize = 0;
    while (connections < http_responses) : (connections += 1) {
        const stream = srv.accept(io) catch return;
        defer {
            var copy = stream;
            copy.close(io);
        }
        var recv_buf: [4096]u8 = undefined;
        var send_buf: [4096]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buf);
        var conn_writer = stream.writer(io, &send_buf);
        var server: std.http.Server = .init(&conn_reader.interface, &conn_writer.interface);
        var req = server.receiveHead() catch return;
        if (std.mem.eql(u8, req.head.target, "/crash")) {
            req.respond("", .{ .status = .internal_server_error }) catch return;
        } else {
            req.respond("", .{ .status = .ok }) catch return;
        }
    }
}

test "httpProbe reads local server statuses" {
    const io = testing.io;
    const port = findOpenPort(io, 41000);
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var srv = addr.listen(io, .{}) catch unreachable;
    defer srv.deinit(io);

    const th = std.Thread.spawn(.{}, srvRun, .{ io, &srv }) catch unreachable;
    defer th.join();

    var url_buf: [64]u8 = undefined;
    const ok_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port}) catch unreachable;
    try testing.expectEqual(.ok, httpProbe(io, ok_url, 200));
    // strict code compare: 5xx is not ok even though the class exists
    const crash_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/crash", .{port}) catch unreachable;
    try testing.expectEqual(.fail, httpProbe(io, crash_url, 200));
    try testing.expectEqual(.ok, httpProbe(io, crash_url, 500));
    const quit_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/done", .{port}) catch unreachable;
    try testing.expectEqual(.ok, httpProbe(io, quit_url, 200));
    // a closed port is fail
    try testing.expectEqual(.fail, httpProbe(io, "http://127.0.0.1:65534/", 200));
}

test "tcpProbe connects through kernel backlog and fails on closed port" {
    const io = testing.io;
    const port = findOpenPort(io, 42000);
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var srv = addr.listen(io, .{}) catch unreachable;
    defer srv.deinit(io);
    try testing.expectEqual(.ok, tcpProbe(io, "127.0.0.1", port));
    try testing.expectEqual(.fail, tcpProbe(io, "127.0.0.1", 65534));
}

test "pingProbe pings localhost" {
    try testing.expectEqual(.ok, pingProbe(testing.allocator, testing.io, "127.0.0.1"));
}
