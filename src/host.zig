//! What a command needs from the world around it, in one parameter.
//!
//! Everything a stage touches that is not its own data lives here: the two
//! allocators, I/O, the repository root, and the way it runs external tools.
//! The Python pipeline reached for module-level globals instead, which is why
//! nothing in it could be tested twice in the same process.

const std = @import("std");
const exec = @import("exec.zig");

pub const Host = struct {
    /// Frees what it allocates. For anything large and short-lived, or that
    /// outlives the stage arena.
    gpa: std.mem.Allocator,
    /// Freed in one go when the command ends. For the document and everything
    /// reachable from it; never call `free` on memory from here.
    arena: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    runner: exec.Runner,

    /// Runs an external tool, and stops the program unless it exited zero. A
    /// tool that half-worked is worse than one that did not run at all: it
    /// leaves behind a file that looks plausible.
    ///
    /// The policy lives here rather than in `exec` so that the transport stays
    /// inspectable, and so the message reaches the user the same way every
    /// other diagnostic does.
    pub fn runChecked(self: Host, request: exec.Request) !exec.Output {
        const output = try self.runner.run(self.gpa, self.io, request);
        if (output.exit_code != 0) {
            std.process.fatal("{s} exited {d}: {s}", .{
                request.argv[0],
                output.exit_code,
                std.mem.trim(u8, output.stderr, &std.ascii.whitespace),
            });
        }
        return output;
    }

    /// One line of progress on stdout. Stages are slow enough that saying what
    /// they did is not noise.
    pub fn report(self: Host, comptime format: []const u8, arguments: anytype) !void {
        var buffer: [4096]u8 = undefined;
        var out: std.Io.File.Writer = .init(.stdout(), self.io, &buffer);
        try out.interface.print(format ++ "\n", arguments);
        try out.interface.flush();
    }
};
