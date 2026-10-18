const std = @import("std");
const alarm = @import("alarm.zig");
const config = @import("config.zig");
const election = @import("election.zig");
const probe = @import("probe.zig");
const telegram = @import("telegram.zig");

const max_config_bytes: usize = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const argv = init.minimal.args.vector;
    var positional: ?[]const u8 = null;
    var secret_files: config.SecretFiles = .{};
    var ai: usize = 1;
    while (ai < argv.len) : (ai += 1) {
        const arg = std.mem.sliceTo(argv[ai], 0);
        if (std.mem.eql(u8, arg, "--token-file") or std.mem.eql(u8, arg, "--chat-id-file")) {
            ai += 1;
            if (ai >= argv.len) usageExit("flag needs a path");
            const value = std.mem.sliceTo(argv[ai], 0);
            if (std.mem.eql(u8, arg, "--token-file")) {
                secret_files.token_file = value;
            } else {
                secret_files.chat_id_file = value;
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            usageExit("unknown flag");
        } else if (positional == null) {
            positional = arg;
        } else {
            usageExit("unexpected extra argument");
        }
    }
    const path = positional orelse "config.json";

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&hostname_buf);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes)) catch |e| {
        std.debug.print("peerpatrol: cannot read config {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(1);
    };
    defer gpa.free(text);
    var loaded = config.load(gpa, io, text, hostname, secret_files) catch |e| {
        std.debug.print("peerpatrol: bad config {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(1);
    };
    defer loaded.deinit();

    log("peerpatrol up: self={s} members={d} checks={d}\n", .{
        loaded.cnf().members[loaded.self_index],
        loaded.cnf().members.len,
        loaded.cnf().checks.len,
    });

    var tg = telegram.Telegram.init(gpa, io, loaded.cnf().telegram.bot_token, loaded.cnf().telegram.chat_id);
    defer tg.client.deinit();
    tg.api_base = loaded.cnf().telegram.api_base;
    var state = alarm.FileTransport{
        .io = io,
        .gpa = gpa,
        .path = loaded.cnf().state_path orelse "monitor-state.txt",
        .inner = tg.transport(),
    };
    const transport = state.transport();
    state.ensureWritable() catch |e| {
        log("peerpatrol: state path {s} not writable: {s}\n", .{ state.path, @errorName(e) });
        std.process.exit(1);
    };

    const members: []const []const u8 = loaded.cnf().members;

    var slots = try gpa.alloc(Slot, loaded.cnf().checks.len);
    defer gpa.free(slots);
    const now = nowSecs(io);
    for (loaded.cnf().checks, 0..) |*c, i| {
        slots[i] = .{
            .check = c,
            .interval = c.interval_secs,
            .offset = election.offsetOf(c.id, c.interval_secs),
            .next = 0,
        };
        slots[i].bump(now);
    }

    while (true) {
        var min_next = slots[0].next;
        for (slots[1..]) |s| min_next = @min(min_next, s.next);
        const deadline: std.Io.Clock.Timestamp = .{
            .raw = .{ .nanoseconds = @as(i96, @intCast(min_next)) * std.time.ns_per_s },
            .clock = .real,
        };
        deadline.wait(io) catch {};
        const woke = nowSecs(io);
        for (slots) |*s| {
            if (s.next > woke) continue;
            s.fire(gpa, io, transport, members, loaded.self_index);
            s.bump(woke);
        }
    }
}

fn usageExit(what: []const u8) noreturn {
    std.debug.print("peerpatrol: usage: peerpatrol [config-path] [--token-file <path>] [--chat-id-file <path>]\n", .{});
    std.debug.print("peerpatrol: {s}\n", .{what});
    std.process.exit(1);
}

fn nowSecs(io: std.Io) u64 {
    // Clock.real is CLOCK_REALTIME over the Unix epoch (docs).
    return @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds()));
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// One check's schedule: fire moments are `bucket*interval + offset` unix
/// seconds; every agent computes the identical timeline and only acts when
/// `elect` names it.
const Slot = struct {
    check: *const config.Check,
    interval: u64,
    offset: u64,
    next: u64,

    fn bump(s: *Slot, now_secs: u64) void {
        var bucket = election.bucketOf(@intCast(now_secs), s.interval);
        var at = bucket * s.interval + s.offset;
        if (at <= now_secs) {
            bucket += 1;
            at += s.interval;
        }
        s.next = at;
    }

    fn fire(s: *Slot, gpa: std.mem.Allocator, io: std.Io, transport: alarm.Transport, members: []const []const u8, self_index: usize) void {
        const bucket = s.next / s.interval;
        if (election.elect(s.check.id, bucket, members) != self_index) return;
        const r: probe.Result = if (std.mem.eql(u8, s.check.@"type", "http"))
            probe.httpProbe(io, s.check.target, s.check.expect orelse config.DEFAULT_HTTP_EXPECT)
        else if (std.mem.eql(u8, s.check.@"type", "tcp"))
            probe.tcpProbe(io, s.check.host, s.check.port)
        else
            probe.pingProbe(gpa, io, s.check.target);
        const action = alarm.handleResult(transport, s.check.id, bucket, r) catch |e| {
            log("{s} @bucket {d}: telegram {s}\n", .{ s.check.id, bucket, @errorName(e) });
            return;
        };
        switch (action) {
            .silent => {},
            .send_down => log("{s} @bucket {d}: DOWN sent (probe fail)\n", .{ s.check.id, bucket }),
            .send_up => log("{s} @bucket {d}: UP sent (probe ok)\n", .{ s.check.id, bucket }),
        }
    }
};
