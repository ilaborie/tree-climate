//! Minimal long-option parser.
//!
//! Every slice it returns points into `argv`, so the parser needs no allocator
//! at all — which is also why none of its tests can leak.
//!
//! Understood: `--name`, `--name=value`, `--name value`, and positionals.
//! Deliberately absent: short options and the `--` separator. No stage of this
//! pipeline has ever used either, and adding them would mean callers must
//! handle cases that cannot occur.

const std = @import("std");

pub const Option = struct {
    name: []const u8,
    /// The value when written as `--name=value`; null for `--name` and
    /// `--name value` alike, so callers always go through `Parser.value`.
    attached: ?[]const u8,
};

pub const Token = union(enum) {
    option: Option,
    positional: []const u8,
};

pub const Parser = struct {
    argv: []const []const u8,
    index: usize = 0,

    pub fn init(argv: []const []const u8) Parser {
        return .{ .argv = argv };
    }

    pub fn next(self: *Parser) ?Token {
        if (self.index == self.argv.len) return null;
        const arg = self.argv[self.index];
        self.index += 1;

        if (!std.mem.startsWith(u8, arg, "--")) return .{ .positional = arg };

        const body = arg[2..];
        const equals = std.mem.indexOfScalar(u8, body, '=') orelse
            return .{ .option = .{ .name = body, .attached = null } };
        return .{ .option = .{
            .name = body[0..equals],
            .attached = body[equals + 1 ..],
        } };
    }

    /// The value of the option `next` just returned: either its inline
    /// `=value` or the following argument, which is consumed.
    pub fn value(self: *Parser, option: Option) error{MissingValue}![]const u8 {
        if (option.attached) |attached| return attached;
        if (self.index == self.argv.len) return error.MissingValue;
        defer self.index += 1;
        return self.argv[self.index];
    }
};

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "separated and attached values are equivalent" {
    for ([_][]const []const u8{
        &.{ "--source", "data/data.json" },
        &.{"--source=data/data.json"},
    }) |argv| {
        var parser: Parser = .init(argv);
        const token = parser.next().?;
        try expectEqualStrings("source", token.option.name);
        try expectEqualStrings("data/data.json", try parser.value(token.option));
        try expect(parser.next() == null);
    }
}

test "a value may itself look like an option" {
    var parser: Parser = .init(&.{ "--base", "--weird" });
    const token = parser.next().?;
    try expectEqualStrings("--weird", try parser.value(token.option));
}

test "an attached value may be empty or contain equals signs" {
    var parser: Parser = .init(&.{ "--base=", "--query=a=b" });

    const empty = parser.next().?;
    try expectEqualStrings("", try parser.value(empty.option));

    const nested = parser.next().?;
    try expectEqualStrings("query", nested.option.name);
    try expectEqualStrings("a=b", try parser.value(nested.option));
}

test "flags and positionals interleave" {
    var parser: Parser = .init(&.{ "site", "--no-images", "--limit", "5", "extra" });

    try expectEqualStrings("site", parser.next().?.positional);

    const flag = parser.next().?;
    try expectEqualStrings("no-images", flag.option.name);
    try expect(flag.option.attached == null);

    const limit = parser.next().?;
    try expectEqualStrings("5", try parser.value(limit.option));

    try expectEqualStrings("extra", parser.next().?.positional);
    try expect(parser.next() == null);
}

test "a trailing option with no value is an error, not a panic" {
    var parser: Parser = .init(&.{"--source"});
    const token = parser.next().?;
    try expectError(error.MissingValue, parser.value(token.option));
}

test "an empty argv yields nothing" {
    var parser: Parser = .init(&.{});
    try expect(parser.next() == null);
}
