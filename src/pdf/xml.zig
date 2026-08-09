//! A pull parser for the XHTML that `pdftotext -bbox` writes.
//!
//! Not an XML parser, and the difference matters. It handles elements,
//! attributes, self-closing tags, comments, `<?…?>`, `<!DOCTYPE …>`, the five
//! predefined entities and numeric character references. It does **not** handle
//! namespaces (element names are compared after the last `:`), CDATA sections,
//! or entities declared in a DTD. That is the whole of what poppler emits, and
//! pretending to more would be a claim this code cannot back.
//!
//! It allocates nothing: every slice it returns points into the input. Callers
//! that need entity-decoded text call `decodeAlloc`.

const std = @import("std");

pub const Error = error{Malformed};

pub const Element = struct {
    /// Local name: whatever follows the last `:`.
    name: []const u8,
    /// The attribute section, verbatim. Walk it with `attribute`.
    attributes: []const u8,

    /// The raw value of `name`, still entity-encoded, or null if absent.
    pub fn attribute(self: Element, name: []const u8) ?[]const u8 {
        var rest = self.attributes;
        while (true) {
            rest = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
            const equals = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
            const key = std.mem.trimEnd(u8, rest[0..equals], &std.ascii.whitespace);

            const quoted = std.mem.trimStart(u8, rest[equals + 1 ..], &std.ascii.whitespace);
            if (quoted.len == 0) return null;
            const quote = quoted[0];
            if (quote != '"' and quote != '\'') return null;
            const end = std.mem.indexOfScalar(u8, quoted[1..], quote) orelse return null;

            if (std.mem.eql(u8, key, name)) return quoted[1 .. 1 + end];
            rest = quoted[end + 2 ..];
        }
    }
};

pub const Event = union(enum) {
    open: Element,
    close: []const u8,
    /// Character data, still entity-encoded. Whitespace between elements shows
    /// up here too; callers that do not want it skip it.
    text: []const u8,
};

pub const Reader = struct {
    source: []const u8,
    index: usize = 0,

    pub fn init(source: []const u8) Reader {
        return .{ .source = source };
    }

    /// The next event, or null at end of input. Always advances, so a caller
    /// looping until null terminates on any input.
    pub fn next(self: *Reader) Error!?Event {
        if (self.index >= self.source.len) return null;

        if (self.source[self.index] != '<') {
            const start = self.index;
            self.index = std.mem.indexOfScalarPos(u8, self.source, start, '<') orelse
                self.source.len;
            return .{ .text = self.source[start..self.index] };
        }

        const rest = self.source[self.index..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            self.index += (std.mem.indexOfPos(u8, self.source, self.index + 4, "-->") orelse
                return error.Malformed) + 3 - self.index;
            return self.next();
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            self.index += (std.mem.indexOfPos(u8, self.source, self.index + 2, "?>") orelse
                return error.Malformed) + 2 - self.index;
            return self.next();
        }
        if (std.mem.startsWith(u8, rest, "<!")) {
            self.index = try self.scanToTagEnd(self.index + 2);
            return self.next();
        }
        if (std.mem.startsWith(u8, rest, "</")) {
            const end = try self.scanToTagEnd(self.index + 2);
            const name = std.mem.trim(u8, self.source[self.index + 2 .. end - 1], &std.ascii.whitespace);
            self.index = end;
            return .{ .close = localName(name) };
        }

        const end = try self.scanToTagEnd(self.index + 1);
        var body = self.source[self.index + 1 .. end - 1];
        self.index = end;
        if (std.mem.endsWith(u8, body, "/")) body = body[0 .. body.len - 1];

        const name_end = std.mem.indexOfAny(u8, body, &std.ascii.whitespace) orelse body.len;
        if (name_end == 0) return error.Malformed;
        return .{ .open = .{
            .name = localName(body[0..name_end]),
            .attributes = body[name_end..],
        } };
    }

    /// Index just past the `>` closing the tag that starts at `from`. Quoted
    /// attribute values may contain `>`, so quotes are tracked.
    fn scanToTagEnd(self: *Reader, from: usize) Error!usize {
        var at = from;
        var quote: ?u8 = null;
        while (at < self.source.len) : (at += 1) {
            const byte = self.source[at];
            if (quote) |open| {
                if (byte == open) quote = null;
            } else switch (byte) {
                '"', '\'' => quote = byte,
                '>' => return at + 1,
                else => {},
            }
        }
        return error.Malformed;
    }
};

fn localName(name: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return name;
    return name[colon + 1 ..];
}

/// Resolves the five predefined entities and numeric character references.
/// Anything else is left alone rather than guessed at.
pub fn decodeAlloc(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return gpa.dupe(u8, raw);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var at: usize = 0;
    while (at < raw.len) {
        if (raw[at] != '&') {
            try out.append(gpa, raw[at]);
            at += 1;
            continue;
        }
        const semicolon = std.mem.indexOfScalarPos(u8, raw, at, ';') orelse {
            try out.append(gpa, raw[at]);
            at += 1;
            continue;
        };
        const name = raw[at + 1 .. semicolon];
        if (try resolve(gpa, &out, name)) {
            at = semicolon + 1;
        } else {
            try out.append(gpa, raw[at]);
            at += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn resolve(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
) std.mem.Allocator.Error!bool {
    const named: []const struct { []const u8, u8 } = &.{
        .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            try out.append(gpa, entry[1]);
            return true;
        }
    }
    if (name.len < 2 or name[0] != '#') return false;

    const hexadecimal = name[1] == 'x' or name[1] == 'X';
    const digits = if (hexadecimal) name[2..] else name[1..];
    const codepoint = std.fmt.parseUnsigned(u21, digits, if (hexadecimal) 16 else 10) catch
        return false;

    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return false;
    try out.appendSlice(gpa, encoded[0..length]);
    return true;
}

const testing_gpa = std.testing.allocator;

/// `expectEqualSlices` on slices of slices compares pointers, not text.
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

const expectEqualStrings = std.testing.expectEqualStrings;

test "reads an element with attributes and text" {
    var reader: Reader = .init("<word xMin=\"1.5\" yMin='2'>Abies</word>");

    const open = (try reader.next()).?.open;
    try expectEqualStrings("word", open.name);
    try expectEqualStrings("1.5", open.attribute("xMin").?);
    try expectEqualStrings("2", open.attribute("yMin").?);
    try std.testing.expect(open.attribute("xMax") == null);

    try expectEqualStrings("Abies", (try reader.next()).?.text);
    try expectEqualStrings("word", (try reader.next()).?.close);
    try std.testing.expect(try reader.next() == null);
}

test "skips the prologue poppler emits" {
    const source =
        \\<?xml version="1.0"?><!DOCTYPE html PUBLIC "-//W3C//DTD" "x.dtd">
        \\<!-- a > inside a comment --><meta name="Producer" content="iLovePDF"/><page/>
    ;
    var reader: Reader = .init(source);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing_gpa);
    while (try reader.next()) |event| switch (event) {
        .open => |element| try names.append(testing_gpa, element.name),
        else => {},
    };
    try expectStrings(&.{ "meta", "page" }, names.items);
}

test "a quoted attribute may contain the closing bracket" {
    var reader: Reader = .init("<meta content=\"a > b\"/>");
    const open = (try reader.next()).?.open;
    try expectEqualStrings("a > b", open.attribute("content").?);
}

test "element names are compared without their namespace" {
    var reader: Reader = .init("<x:word/></x:word>");
    try expectEqualStrings("word", (try reader.next()).?.open.name);
    try expectEqualStrings("word", (try reader.next()).?.close);
}

test "decodes the entities poppler actually emits" {
    for ([_][2][]const u8{
        .{ "Pyrus salicifolia &apos;Pendula&apos;", "Pyrus salicifolia 'Pendula'" },
        .{ "a &amp; b &lt;c&gt; &quot;d&quot;", "a & b <c> \"d\"" },
        .{ "&#39;&#x2019;", "'\u{2019}" },
        .{ "no entity here", "no entity here" },
        .{ "a & b", "a & b" },
        .{ "&unknown; &#zz;", "&unknown; &#zz;" },
    }) |case| {
        const decoded = try decodeAlloc(testing_gpa, case[0]);
        defer testing_gpa.free(decoded);
        try expectEqualStrings(case[1], decoded);
    }
}

test "an unterminated tag is an error, not a hang" {
    var reader: Reader = .init("<word xMin=\"1\"");
    try std.testing.expectError(error.Malformed, reader.next());
}

test "the parser survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_gpa, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const decoded = try decodeAlloc(gpa, "&apos;a&amp;b&#233;&#x2019;c&apos;");
            defer gpa.free(decoded);
        }
    }.run, .{});
}

test "the parser never panics and never escapes its input" {
    try std.testing.fuzz({}, fuzzReader, .{});
}

fn fuzzReader(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buffer: [512]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];

    var reader: Reader = .init(source);
    var previous: usize = 0;
    while (reader.next() catch return) |event| {
        // Strictly advancing is what guarantees the loop above terminates.
        try std.testing.expect(reader.index > previous);
        previous = reader.index;

        const slice = switch (event) {
            .open => |element| element.attributes,
            .close, .text => |bytes| bytes,
        };
        try std.testing.expect(contains(source, slice));
    }

    const decoded = try decodeAlloc(testing_gpa, source);
    defer testing_gpa.free(decoded);
    try std.testing.expect(std.unicode.utf8ValidateSlice(source) == false or
        decoded.len <= source.len);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    const start = @intFromPtr(haystack.ptr);
    const at = @intFromPtr(needle.ptr);
    return at >= start and at + needle.len <= start + haystack.len;
}
