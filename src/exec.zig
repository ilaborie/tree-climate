//! Running external programs, behind an interface so that tests can answer
//! without spawning anything.
//!
//! The pipeline shells out to `pdftotext`, `magick` and `curl`. Each is a
//! mature tool doing a job that would be a project in itself to reimplement,
//! and none of them needs to be reimplemented to be tested — only replaced.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{CommandKilled} || Allocator.Error;

pub const Request = struct {
    argv: []const []const u8,
    stdout_limit: std.Io.Limit = .limited(64 << 20),
    stderr_limit: std.Io.Limit = .limited(64 << 10),
};

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: Output, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const Runner = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque, gpa: Allocator, io: std.Io, request: Request) anyerror!Output,

    pub fn run(self: Runner, gpa: Allocator, io: std.Io, request: Request) anyerror!Output {
        return self.runFn(self.context, gpa, io, request);
    }
};

/// The real thing.
pub const System = struct {
    pub fn runner(self: *System) Runner {
        return .{ .context = self, .runFn = spawn };
    }

    fn spawn(_: *anyopaque, gpa: Allocator, io: std.Io, request: Request) anyerror!Output {
        const result = try std.process.run(gpa, io, .{
            .argv = request.argv,
            .stdout_limit = request.stdout_limit,
            .stderr_limit = request.stderr_limit,
        });
        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .exit_code = switch (result.term) {
                .exited => |code| code,
                // A signalled process has no exit code, and treating it as
                // failure-with-code-1 would hide a crash as a bad argument.
                else => return Error.CommandKilled,
            },
        };
    }
};

/// Answers from a script of canned replies, handed out in order.
///
/// In order rather than matched on the program name, because what most needs
/// testing is a sequence: a server that fails twice and then succeeds.
/// Test-only, but it lives here so the interface and its double stay together.
pub const Fake = struct {
    replies: []const Reply,
    next: usize = 0,
    calls: std.ArrayList([]const []const u8) = .empty,

    pub const Reply = struct {
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        exit_code: u8 = 0,
    };

    pub fn runner(self: *Fake) Runner {
        return .{ .context = self, .runFn = reply };
    }

    pub fn deinit(self: *Fake, gpa: Allocator) void {
        self.calls.deinit(gpa);
    }

    fn reply(context: *anyopaque, gpa: Allocator, _: std.Io, request: Request) anyerror!Output {
        const self: *Fake = @ptrCast(@alignCast(context));
        try self.calls.append(gpa, request.argv);
        if (self.next >= self.replies.len) return error.Unexpected;
        const candidate = self.replies[self.next];
        self.next += 1;
        return .{
            .stdout = try gpa.dupe(u8, candidate.stdout),
            .stderr = try gpa.dupe(u8, candidate.stderr),
            .exit_code = candidate.exit_code,
        };
    }
};

const testing_gpa = std.testing.allocator;

test "a fake runner answers in order and records the call" {
    var fake: Fake = .{ .replies = &.{.{ .stdout = "<doc/>" }} };
    defer fake.deinit(testing_gpa);

    const output = try fake.runner().run(testing_gpa, std.testing.io, .{
        .argv = &.{ "pdftotext", "-bbox", "x.pdf", "-" },
    });
    defer output.deinit(testing_gpa);

    try std.testing.expectEqualStrings("<doc/>", output.stdout);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try std.testing.expectEqualStrings("-bbox", fake.calls.items[0][1]);
}

test "a failing program reports its exit code and its stderr" {
    var fake: Fake = .{ .replies = &.{.{
        .exit_code = 1,
        .stderr = "no decode delegate",
    }} };
    defer fake.deinit(testing_gpa);

    const output = try fake.runner().run(testing_gpa, std.testing.io, .{ .argv = &.{"magick"} });
    defer output.deinit(testing_gpa);

    // Host.runChecked is what turns this into a fatal error; keeping the policy
    // out of the transport is what lets a caller inspect a failure instead.
    try std.testing.expectEqual(@as(u8, 1), output.exit_code);
    try std.testing.expectEqualStrings("no decode delegate", output.stderr);
}
