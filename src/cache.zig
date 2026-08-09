//! On-disk memoisation of API responses.
//!
//! Every response is stored under data/cache/<source>/<slug>.json, so a second
//! run makes no network call at all. Absences (404) are cached too, as
//! `{"__absent__": true}` -- otherwise every run would re-ask for the same
//! missing page. Server errors are never cached: those are ours to retry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Host = @import("host.zig").Host;
const text = @import("text.zig");

pub const default_root = "data/cache";

/// A response that was found in the cache; `absent` records a page the source
/// does not have.
pub const Entry = union(enum) {
    absent,
    present: std.json.Value,
};

pub const Cache = struct {
    host: Host,
    root: []const u8 = default_root,

    /// Leaky: the parsed value is allocated in `arena`.
    pub fn readLeaky(
        self: Cache,
        arena: Allocator,
        source: []const u8,
        key: []const u8,
    ) !?Entry {
        const path = try self.pathLeaky(arena, source, key);
        const bytes = self.host.root.readFileAlloc(
            self.host.io,
            path,
            arena,
            .limited(32 << 20),
        ) catch return null;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
            // A truncated entry is one an interrupted write left behind. Writes
            // are atomic now, so this should not happen; treat it as a miss
            // rather than as a reason to stop.
            return null;
        };
        if (parsed == .object and parsed.object.get("__absent__") != null) return .absent;
        return .{ .present = parsed };
    }

    pub fn write(
        self: Cache,
        source: []const u8,
        key: []const u8,
        payload: ?std.json.Value,
    ) !void {
        const path = try self.pathLeaky(self.host.arena, source, key);
        defer self.host.arena.free(path);

        var atomic = try self.host.root.createFileAtomic(self.host.io, path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.host.io);

        var buffer: [64 * 1024]u8 = undefined;
        var file: std.Io.File.Writer = .init(atomic.file, self.host.io, &buffer);
        if (payload) |value| {
            try std.json.Stringify.value(value, .{}, &file.interface);
        } else {
            try file.interface.writeAll("{\"__absent__\":true}");
        }
        try file.interface.flush();
        try atomic.replace(self.host.io);
    }

    fn pathLeaky(self: Cache, arena: Allocator, source: []const u8, key: []const u8) ![]u8 {
        const slug = try text.slugAlloc(arena, key);
        defer arena.free(slug);
        return std.fmt.allocPrint(arena, "{s}/{s}/{s}.json", .{ self.root, source, slug });
    }
};
