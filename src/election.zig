const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn bucketOf(unix_secs: i64, interval_secs: u64) u64 {
    if (unix_secs < 0) return 0;
    return @intCast(@divFloor(unix_secs, @as(i64, @intCast(interval_secs))));
}

pub fn offsetOf(check_id: []const u8, interval_secs: u64) u64 {
    var digest: [32]u8 = undefined;
    Sha256.hash(check_id, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .big) % interval_secs;
}

pub fn elect(check_id: []const u8, bucket: u64, sorted_members: []const []const u8) usize {
    var h = Sha256.init(.{});
    h.update(check_id);
    var buf: [20]u8 = undefined;
    const bucket_txt = std.fmt.bufPrint(&buf, "{d}", .{bucket}) catch |e| switch (e) {
        error.NoSpaceLeft => unreachable, // longest u64 decimal is exactly 20 bytes
    };
    h.update(bucket_txt);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return @intCast(std.mem.readInt(u64, digest[0..8], .big) % sorted_members.len);
}

const testing = std.testing;

test "bucketOf floors the minute" {
    try testing.expectEqual(@as(u64, 0), bucketOf(0, 60));
    try testing.expectEqual(@as(u64, 0), bucketOf(59, 60));
    try testing.expectEqual(@as(u64, 1), bucketOf(60, 60));
    try testing.expectEqual(@as(u64, 1), bucketOf(61, 60));
    try testing.expectEqual(@as(u64, 0), bucketOf(-1, 60));
}

test "offsetOf spreads checks across the interval" {
    const a = offsetOf("web.example.com:https", 60);
    const b = offsetOf("ping.router.lan", 60);
    try testing.expect(a < 60);
    try testing.expect(b < 60);
    try testing.expectEqual(a, offsetOf("web.example.com:https", 60));
}

test "golden hashes" {
    // taped from one run; if these change, every agent's schedule diverges — stop and think
    try testing.expectEqual(@as(u64, 146), offsetOf("check:web", 300));
    try testing.expectEqual(@as(u64, 9), offsetOf("https://node-b:443", 60));
    const members = [_][]const u8{ "alpha", "node-b.example.com", "node-c.example.com" };
    try testing.expectEqualStrings("alpha", members[elect("check:web", 0, &members)]);
    try testing.expectEqualStrings("node-c.example.com", members[elect("check:web", 1, &members)]);
    try testing.expectEqualStrings("node-c.example.com", members[elect("check:web", 2, &members)]);
    try testing.expectEqualStrings("node-c.example.com", members[elect("check:web", 3, &members)]);
}

test "elect rotates over buckets and stays in bounds" {
    const members = [_][]const u8{ "alpha", "node-b.example.com", "node-c.example.com" };
    var counts = [_]usize{0} ** members.len;
    for (0..48) |bucket| {
        const idx = elect("check:web", @intCast(bucket), &members);
        counts[idx] += 1;
    }
    for (counts) |c| try testing.expect(c > 0); // all members reachable
    try testing.expectEqual(elect("check:web", 7, &members), elect("check:web", 7, &members));
}
