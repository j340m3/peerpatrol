const std = @import("std");
const probe = @import("probe.zig");

pub const State = enum { down, up };

/// What to do given the last known state and a fresh probe result.
pub const Action = enum { silent, send_down, send_up };

pub fn decide(last: ?State, result: probe.Result) Action {
    return switch (result) {
        .fail => if (last == .down) .silent else .send_down,
        .ok => if (last == .down) .send_up else .silent,
    };
}

/// Parse a chat text like "DOWN web @bucket 12" for a given check id.
/// Word boundary after the check id prevents "DOWN webfoo" matching "web".
pub fn stateFromText(check_id: []const u8, text: []const u8) ?State {
    if (std.mem.startsWith(u8, text, "DOWN ")) {
        if (endsCheck(text[5..], check_id)) return .down;
    } else if (std.mem.startsWith(u8, text, "UP ")) {
        if (endsCheck(text[3..], check_id)) return .up;
    }
    return null;
}

fn endsCheck(rest: []const u8, check_id: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, check_id)) return false;
    const after = rest[check_id.len..];
    return after.len == 0 or after[0] == ' ';
}

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        lastState: *const fn (ctx: *anyopaque, check_id: []const u8) anyerror!?State,
        send: *const fn (ctx: *anyopaque, text: []const u8) anyerror!void,
    };

    pub fn lastState(t: Transport, check_id: []const u8) anyerror!?State {
        return t.vtable.lastState(t.ctx, check_id);
    }

    pub fn send(t: Transport, text: []const u8) anyerror!void {
        return t.vtable.send(t.ctx, text);
    }
};

/// Alarm state persisted to a local file; every transition is also forwarded
/// to `inner` (Telegram). The file is authoritative for state, the chat is
/// the alarm surface. Reads via the same DOWN/UP text format the chat uses.
/// ponytail ceiling: a host's file can't see other hosts' transitions —
/// recovery (UP) happens when the DOWN-firing host is checker again, and a
/// checker change during an outage re-sends DOWN; fixed by peer transport
/// (a v1 non-goal). 1 MiB state cap: files grow per transition, not per probe.
pub const FileTransport = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    inner: Transport,

    const vtable = Transport.VTable{ .lastState = lastStateFn, .send = sendFn };

    pub fn transport(self: *FileTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Fail fast at startup when the state file cannot be rewritten (also
    /// creates it when missing). Otherwise an unwritable directory defeats the
    /// local dedup: every failing probe would re-post DOWN to the chat — the
    /// exact spam mode the ticket-05 smoke saw from the stale pre-fallback
    /// binary.
    pub fn ensureWritable(self: *FileTransport) !void {
        const existing = (try self.readStateFile()) orelse "";
        defer if (existing.len > 0) self.gpa.free(existing);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = existing });
    }

    fn readStateFile(f: *FileTransport) !?[]u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(f.io, f.path, f.gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        return data;
    }

    fn lastStateFn(ctx: *anyopaque, check_id: []const u8) anyerror!?State {
        const f: *FileTransport = @ptrCast(@alignCast(ctx));
        const data = (try readStateFile(f)) orelse return null;
        defer f.gpa.free(data);
        var last: ?State = null;
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (stateFromText(check_id, line)) |s| last = s;
        }
        return last;
    }

    fn sendFn(ctx: *anyopaque, text: []const u8) anyerror!void {
        const f: *FileTransport = @ptrCast(@alignCast(ctx));
        const existing = (try readStateFile(f)) orelse "";
        defer if (existing.len > 0) f.gpa.free(existing);
        const wbuf = try f.gpa.alloc(u8, existing.len + text.len + 1);
        defer f.gpa.free(wbuf);
        @memcpy(wbuf[0..existing.len], existing);
        @memcpy(wbuf[existing.len..][0..text.len], text);
        wbuf[existing.len + text.len] = '\n';
        try std.Io.Dir.cwd().writeFile(f.io, .{ .sub_path = f.path, .data = wbuf[0 .. existing.len + text.len + 1] });
        try f.inner.send(text);
    }
};

/// One alarm-transition decision and (maybe) one message, per probe result.
pub fn handleResult(t: Transport, check_id: []const u8, bucket: u64, result: probe.Result) !Action {
    const last = try t.lastState(check_id);
    switch (decide(last, result)) {
        .silent => return .silent,
        .send_down => {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "DOWN {s} @bucket {d}", .{ check_id, bucket });
            try t.send(text);
            return .send_down;
        },
        .send_up => {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "UP {s}", .{check_id});
            try t.send(text);
            return .send_up;
        },
    }
}

const Fake = struct {
    gpa: std.mem.Allocator,
    history: std.ArrayList([]u8),

    fn init(gpa: std.mem.Allocator) Fake {
        return .{ .gpa = gpa, .history = .empty };
    }
    fn deinit(f: *Fake) void {
        for (f.history.items) |h| f.gpa.free(h);
        f.history.deinit(f.gpa);
    }
    fn transport(f: *Fake) Transport {
        return .{ .ctx = f, .vtable = &vtable };
    }
    const vtable = Transport.VTable{
        .lastState = lastStateFn,
        .send = sendFn,
    };
    fn lastStateFn(ctx: *anyopaque, check_id: []const u8) anyerror!?State {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        var i = f.history.items.len;
        while (i > 0) {
            i -= 1;
            if (stateFromText(check_id, f.history.items[i])) |s| return s;
        }
        return null;
    }
    fn sendFn(ctx: *anyopaque, text: []const u8) anyerror!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        try f.history.append(f.gpa, try f.gpa.dupe(u8, text));
    }
};

test "empty history + ok is silent" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    const action = try handleResult(fake.transport(), "web", 1, .ok);
    try std.testing.expectEqual(Action.silent, action);
}

test "fail opens alarm with DOWN message" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    const action = try handleResult(fake.transport(), "web", 7, .fail);
    try std.testing.expectEqual(Action.send_down, action);
    try std.testing.expectEqualStrings("DOWN web @bucket 7", fake.history.items[0]);
}

test "fail twice sends one DOWN only" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    try std.testing.expectEqual(Action.send_down, try handleResult(fake.transport(), "web", 7, .fail));
    try std.testing.expectEqual(Action.silent, try handleResult(fake.transport(), "web", 8, .fail));
    try std.testing.expectEqual(@as(usize, 1), fake.history.items.len);
}

test "down history + ok sends UP" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    try fake.history.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "DOWN web @bucket 3"));
    const action = try handleResult(fake.transport(), "web", 4, .ok);
    try std.testing.expectEqual(Action.send_up, action);
    try std.testing.expectEqualStrings("UP web", fake.history.items[1]);
}

test "up history + ok is silent" {
    var fake = Fake.init(std.testing.allocator);
    defer fake.deinit();
    try fake.history.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "UP web"));
    const action = try handleResult(fake.transport(), "web", 4, .ok);
    try std.testing.expectEqual(Action.silent, action);
}

test "stateFromText word boundaries and misspellings" {
    try std.testing.expectEqual(State.down, stateFromText("web", "DOWN web @bucket 3").?);
    try std.testing.expectEqual(State.down, stateFromText("web", "DOWN web").?);
    try std.testing.expectEqual(State.up, stateFromText("gateway.lan:22", "UP gateway.lan:22").?);
    try std.testing.expectEqual(@as(?State, null), stateFromText("web", "DOWN webfoo"));
    try std.testing.expectEqual(@as(?State, null), stateFromText("web", "web is down"));
    try std.testing.expectEqual(@as(?State, null), stateFromText("other", "DOWN web @bucket 3"));
}

test "FileTransport round-trips state and forwards to chat" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // tmpDir's dirs are relative to its own cwd; resolve the real path so the
    // FileTransport (Dir.cwd()) reaches the file regardless of the exe cwd.
    var realpathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &realpathbuf);
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pathbuf, "{s}/state.txt", .{realpathbuf[0..real_len]});

    var fake = Fake.init(gpa);
    defer fake.deinit();

    var ft = FileTransport{ .io = io, .gpa = gpa, .path = path, .inner = fake.transport() };

    try std.testing.expectEqual(@as(?State, null), try ft.transport().lastState("web"));
    try std.testing.expectEqual(Action.send_down, try handleResult(ft.transport(), "web", 7, .fail));
    try std.testing.expectEqual(@as(?State, .down), try ft.transport().lastState("web"));
    try std.testing.expectEqual(@as(usize, 1), fake.history.items.len);

    // restart recovery: fresh agent instance, same state file
    var ft2 = FileTransport{ .io = io, .gpa = gpa, .path = path, .inner = fake.transport() };
    try std.testing.expectEqual(@as(?State, .down), try ft2.transport().lastState("web"));
    try std.testing.expectEqual(@as(?State, null), try ft2.transport().lastState("other"));

    // recovery closes the alarm in file and chat
    try std.testing.expectEqual(Action.send_up, try handleResult(ft2.transport(), "web", 8, .ok));
    try std.testing.expectEqual(@as(?State, .up), try ft2.transport().lastState("web"));
    try std.testing.expectEqual(@as(usize, 2), fake.history.items.len);
    try std.testing.expectEqualStrings("UP web", fake.history.items[1]);
}

test "ensureWritable creates missing file and fails on a bad path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var realpathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &realpathbuf);
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pathbuf, "{s}/state.txt", .{realpathbuf[0..real_len]});

    var fake = Fake.init(gpa);
    defer fake.deinit();
    var ft = FileTransport{ .io = io, .gpa = gpa, .path = path, .inner = fake.transport() };
    try ft.ensureWritable();
    const data = (try ft.readStateFile()).?;
    defer gpa.free(data);
    try std.testing.expectEqualStrings("", data);
    try std.testing.expectEqual(@as(usize, 0), fake.history.items.len);

    var bad = FileTransport{ .io = io, .gpa = gpa, .path = "/nonexistent-dir/state.txt", .inner = fake.transport() };
    try std.testing.expectError(error.FileNotFound, bad.ensureWritable());
}
