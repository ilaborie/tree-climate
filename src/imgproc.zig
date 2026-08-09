//! Image derivatives, via ImageMagick.
//!
//! The masters in img/ stay JPEG because Typst cannot embed WebP without
//! re-encoding it, which multiplied the PDF by seven when measured. The site
//! therefore builds its own WebP derivatives instead of sharing the masters.

const std = @import("std");
const Host = @import("host.zig").Host;

pub const Outcome = enum { built, reused, master_missing };

/// Produces both widths of one master, and says whether it had to.
///
/// One process for the two sizes: `-write` emits an intermediate result without
/// closing the chain, so the smaller derivative is resized from the larger one
/// rather than from the master a second time.
pub fn deriveWebp(
    host: Host,
    master: []const u8,
    wide_target: []const u8,
    narrow_target: []const u8,
    wide: u32,
    narrow: u32,
    quality: u32,
) !Outcome {
    const master_time = modifiedAt(host, master) orelse return .master_missing;
    if (isFresh(host, wide_target, master_time) and isFresh(host, narrow_target, master_time)) {
        return .reused;
    }

    const output = try host.runChecked(.{ .argv = &.{
        "magick",
        master,
        "-strip",
        "-quality",
        try std.fmt.allocPrint(host.arena, "{d}", .{quality}),
        "-define",
        "webp:method=6",
        "-resize",
        try std.fmt.allocPrint(host.arena, "{d}x>", .{wide}),
        "-write",
        wide_target,
        "-resize",
        try std.fmt.allocPrint(host.arena, "{d}x>", .{narrow}),
        narrow_target,
    } });
    output.deinit(host.gpa);
    return .built;
}

fn modifiedAt(host: Host, path: []const u8) ?i96 {
    const stat = host.root.statFile(host.io, path, .{}) catch return null;
    return stat.mtime.nanoseconds;
}

fn isFresh(host: Host, target: []const u8, master_time: i96) bool {
    const target_time = modifiedAt(host, target) orelse return false;
    return target_time >= master_time;
}
