//! Reading and writing the pipeline's JSON documents, in one canonical format.

const std = @import("std");

/// The Python pipeline wrote every file with
/// `json.dumps(..., ensure_ascii=False, indent=2)` plus a trailing newline.
/// `.indent_2` reproduces it exactly: two-space indent, one space after each
/// colon, and no `\u` escaping. Keeping the format identical is what turns the
/// round-trip test into a proof rather than an approximation.
pub const format: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

/// Reads and parses `path` as `T`.
///
/// Leaky, in the sense `std.json` gives the word: the result borrows from the
/// file bytes, which are themselves allocated in `arena`. Both live until the
/// arena is reset — passing a shorter-lived allocator here hands back dangling
/// slices, silently.
///
/// Unknown fields are rejected. A key the schema does not know about means the
/// data drifted from `model.zig`, and that is worth stopping for.
pub fn readLeaky(
    comptime T: type,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    limit: std.Io.Limit,
) !T {
    const bytes = try dir.readFileAlloc(io, path, arena, limit);
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{});
}

/// Same, for a file whose schema belongs to someone else -- Vite's manifest,
/// say. Unknown fields are ignored, because the other project is free to add
/// one and that is not a reason to fail a build.
pub fn readForeignLeaky(
    comptime T: type,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    limit: std.Io.Limit,
) !T {
    const bytes = try dir.readFileAlloc(io, path, arena, limit);
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Serialises `document` in the canonical format, trailing newline included.
pub fn stringifyAlloc(gpa: std.mem.Allocator, document: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(document, format, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Writes `document` to `path`, creating parent directories as needed.
///
/// The file appears complete or not at all. That is not belt-and-braces: the
/// Python cache needed a recovery path for entries truncated by an interrupted
/// write, and this removes the failure instead of porting the workaround.
pub fn writeAtomic(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    document: anytype,
) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(atomic.file, io, &buffer);
    try std.json.Stringify.value(document, format, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();

    try atomic.replace(io);
}

test "the canonical format matches Python's json.dumps(indent=2)" {
    const gpa = std.testing.allocator;
    const Sample = struct {
        name: []const u8,
        height_m: ?u32,
        tags: []const []const u8,
    };

    const rendered = try stringifyAlloc(gpa, Sample{
        .name = "Chêne « vert »",
        .height_m = null,
        .tags = &.{"a"},
    });
    defer gpa.free(rendered);

    try std.testing.expectEqualStrings(
        \\{
        \\  "name": "Chêne « vert »",
        \\  "height_m": null,
        \\  "tags": [
        \\    "a"
        \\  ]
        \\}
        \\
    , rendered);
}

test "an empty array stays on one line, as Python writes it" {
    const gpa = std.testing.allocator;
    const rendered = try stringifyAlloc(gpa, .{ .warnings = &[_][]const u8{} });
    defer gpa.free(rendered);

    try std.testing.expectEqualStrings(
        \\{
        \\  "warnings": []
        \\}
        \\
    , rendered);
}
