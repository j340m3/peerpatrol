const std = @import("std");

pub const DEFAULT_INTERVAL_SECS: u64 = 60;
pub const DEFAULT_HTTP_EXPECT: u16 = 200;

/// Optional paths to files holding the telegram credentials; their contents
/// override the JSON values before validation (so an empty token file fails
/// like an empty token would).
pub const SecretFiles = struct {
    token_file: ?[]const u8 = null,
    chat_id_file: ?[]const u8 = null,
};

pub const Telegram = struct {
    bot_token: []const u8,
    chat_id: i64,
    /// Bot API base; overridable for test mocks and self-hosted bridges.
    api_base: []const u8 = "https://api.telegram.org",
};

pub const Check = struct {
    /// Optional check name; used in messages and hashes (spec: name or type+target).
    name: ?[]const u8 = null,
    @"type": []const u8,
    target: []const u8,
    expect: ?u16 = null,
    interval_secs: u64 = DEFAULT_INTERVAL_SECS,
    /// Derived at load: `name`, or `"<type>:<target>"` when unnamed.
    id: []const u8 = "",
    /// Derived at load for tcp checks: target split at the last ':'.
    host: []const u8 = "",
    port: u16 = 0,
};

pub const Config = struct {
    telegram: Telegram,
    members: [][]const u8,
    checks: []Check,
    /// Local file that remembers this host's alarm transitions (default
    /// "monitor-state.txt" next to the working directory).
    state_path: ?[]const u8 = null,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(Config),
    /// Position of this host's hostname in the sorted members list.
    self_index: usize,

    pub fn deinit(l: *Loaded) void {
        l.parsed.deinit();
    }

    /// Borrow the parsed config. The pointer is only valid while this Loaded
    /// is alive at its current address (do not copy the struct around).
    pub fn cnf(l: *const Loaded) *const Config {
        return &l.parsed.value;
    }
};

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Read a small secret file and strip the whitespace editors and sops
/// decryption habitually leave behind.
fn readTrimmed(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096));
    return std.mem.trim(u8, bytes, " \n\r\t");
}

/// Apply secret-file texts over the parsed JSON values; pure so the
/// semantics are testable without touching the filesystem.
fn applySecrets(arena: std.mem.Allocator, cnf: *Config, token_text: []const u8, chat_id_text: ?[]const u8) !void {
    cnf.telegram.bot_token = try arena.dupe(u8, std.mem.trim(u8, token_text, " \n\r\t"));
    if (chat_id_text) |t| {
        const trimmed = std.mem.trim(u8, t, " \n\r\t");
        cnf.telegram.chat_id = std.fmt.parseInt(i64, trimmed, 10) catch return error.ChatIdNotInt;
    }
}

/// Parse and normalize: derive check ids, defaults, tcp host/port split,
/// sort members, and locate this host. Errors on missing ("agents error out
/// when self not in members" per spec) or ambiguous hostname matches.
pub fn load(gpa: std.mem.Allocator, io: std.Io, text: []const u8, hostname: []const u8, secret_files: SecretFiles) !Loaded {
    var parsed = try std.json.parseFromSlice(Config, gpa, text, .{});
    errdefer parsed.deinit();
    const cnf: *Config = &parsed.value;
    const arena = parsed.arena.allocator();

    if (secret_files.token_file != null or secret_files.chat_id_file != null) {
        const token_text = if (secret_files.token_file) |p| try readTrimmed(arena, io, p) else cnf.telegram.bot_token;
        const chat_id_text = if (secret_files.chat_id_file) |p| try readTrimmed(arena, io, p) else null;
        try applySecrets(arena, cnf, token_text, chat_id_text);
    }

    if (cnf.telegram.bot_token.len == 0) return error.EmptyBotToken;
    if (cnf.members.len == 0) return error.NoMembers;

    for (cnf.checks) |*c| {
        if (std.mem.eql(u8, c.@"type", "http")) {
            if (c.expect == null) c.expect = DEFAULT_HTTP_EXPECT;
        } else if (std.mem.eql(u8, c.@"type", "tcp")) {
            const colon = std.mem.lastIndexOfScalar(u8, c.target, ':') orelse return error.TcpTargetNoPort;
            c.host = c.target[0..colon];
            c.port = std.fmt.parseInt(u16, c.target[colon + 1 ..], 10) catch return error.TcpTargetBadPort;
            if (c.host.len == 0 or c.port == 0) return error.TcpTargetBadPort;
        } else if (!std.mem.eql(u8, c.@"type", "ping")) {
            return error.UnknownCheckType;
        }
        c.id = if (c.name) |n| n else try std.fmt.allocPrint(arena, "{s}:{s}", .{ c.@"type", c.target });
    }

    std.mem.sort([]const u8, cnf.members, {}, strLess);

    var hits: usize = 0;
    var self_index: usize = 0;
    for (cnf.members, 0..) |m, i| {
        if (std.mem.eql(u8, m, hostname)) {
            hits += 1;
            self_index = i;
        }
    }
    if (hits != 1) return error.MemberSelfMismatch;

    return .{ .parsed = parsed, .self_index = self_index };
}

const testing = std.testing;

const sample_cfg =
    \\{
    \\  "telegram": { "bot_token": "tok", "chat_id": 123 },
    \\  "members": ["zeta", "alpha"],
    \\  "checks": [
    \\    { "name": "web", "type": "http", "target": "https://example.com", "interval_secs": 120 },
    \\    { "type": "tcp", "target": "gateway.lan:22" },
    \\    { "type": "ping", "target": "gateway.lan" }
    \\  ]
    \\}
;

const dup_cfg =
    \\{"telegram":{"bot_token":"tok","chat_id":1},
    \\ "members":["zeta","alpha","zeta"],
    \\ "checks":[{"type":"ping","target":"h"}]}
;

const bad_tcp_cfg =
    \\{"telegram":{"bot_token":"tok","chat_id":1},
    \\ "members":["a"],
    \\ "checks":[{"type":"tcp","target":"gateway.lan"}]}
;

const bad_type_cfg =
    \\{"telegram":{"bot_token":"tok","chat_id":1},
    \\ "members":["a"],
    \\ "checks":[{"type":"exec","target":"/bin/true"}]}
;

test "load derives ids, defaults, sorts members, locates self" {
    var l = try load(testing.allocator, testing.io, sample_cfg, "alpha", .{});
    defer l.deinit();
    const cnf = l.cnf();
    try testing.expectEqualStrings("web", cnf.checks[0].id);
    try testing.expectEqualStrings("tcp:gateway.lan:22", cnf.checks[1].id);
    try testing.expectEqualStrings("ping:gateway.lan", cnf.checks[2].id);
    try testing.expectEqual(@as(u64, 120), cnf.checks[0].interval_secs);
    try testing.expectEqual(DEFAULT_INTERVAL_SECS, cnf.checks[1].interval_secs);
    try testing.expectEqual(@as(?u16, 200), cnf.checks[0].expect);
    try testing.expectEqual(@as(?u16, null), cnf.checks[1].expect);
    try testing.expectEqualStrings("gateway.lan", cnf.checks[1].host);
    try testing.expectEqual(@as(u16, 22), cnf.checks[1].port);
    try testing.expectEqualStrings("alpha", cnf.members[0]);
    try testing.expectEqualStrings("zeta", cnf.members[1]);
    try testing.expectEqual(@as(usize, 0), l.self_index);
}

test "load rejects missing/ambiguous self, bad tcp target, unknown type" {
    // not in members at all
    try testing.expectError(error.MemberSelfMismatch, load(testing.allocator, testing.io, sample_cfg, "gamma", .{}));
    // hostname "zeta" appears twice: ambiguous
    try testing.expectError(error.MemberSelfMismatch, load(testing.allocator, testing.io, dup_cfg, "zeta", .{}));
    // tcp target without port
    try testing.expectError(error.TcpTargetNoPort, load(testing.allocator, testing.io, bad_tcp_cfg, "a", .{}));
    // unknown check type
    try testing.expectError(error.UnknownCheckType, load(testing.allocator, testing.io, bad_type_cfg, "a", .{}));
}

test "applySecrets trims and overrides telegram values before validation" {
    var parsed = try std.json.parseFromSlice(Config, testing.allocator, sample_cfg, .{});
    defer parsed.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try applySecrets(arena, &parsed.value, "tok-from-file\n", " -1001234567890 \n");
    try testing.expectEqualStrings("tok-from-file", parsed.value.telegram.bot_token);
    try testing.expectEqual(@as(i64, -1001234567890), parsed.value.telegram.chat_id);
}

test "applySecrets rejects non-integer chat id" {
    var parsed = try std.json.parseFromSlice(Config, testing.allocator, sample_cfg, .{});
    defer parsed.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.ChatIdNotInt, applySecrets(arena_state.allocator(), &parsed.value, "tok", "not-a-number"));
}
