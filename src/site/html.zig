//! HTML written straight to a writer, with escaping that cannot be forgotten.
//!
//! The Python this replaces built strings and left escaping to the caller,
//! which meant every one of a hundred call sites had to remember. Here `text`
//! escapes and `raw` does not, the names say which is which, and attribute
//! values have no unescaped path at all.

const std = @import("std");
const Writer = std.Io.Writer;

/// Escapes the five characters `html.escape(s, quote=True)` escapes, and with
/// the same spellings, so output stays comparable with the Python's.
pub fn escape(out: *Writer, value: []const u8) Writer.Error!void {
    var rest = value;
    while (std.mem.indexOfAny(u8, rest, "&<>\"'")) |at| {
        try out.writeAll(rest[0..at]);
        try out.writeAll(switch (rest[at]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => "&#x27;",
        });
        rest = rest[at + 1 ..];
    }
    try out.writeAll(rest);
}

pub const Builder = struct {
    out: *Writer,

    /// Already-formed HTML. Never reachable from data.
    pub fn raw(self: Builder, html: []const u8) Writer.Error!void {
        try self.out.writeAll(html);
    }

    /// Character data, escaped.
    pub fn text(self: Builder, value: []const u8) Writer.Error!void {
        try escape(self.out, value);
    }

    pub fn print(self: Builder, comptime format: []const u8, args: anytype) Writer.Error!void {
        try self.out.print(format, args);
    }

    /// `.{ .class_ = "card" }` becomes `class="card"`, `.{ .data_root = ".." }`
    /// becomes `data-root=".."`, `true` becomes a bare boolean attribute, and
    /// null is left out entirely.
    pub fn open(self: Builder, comptime tag: []const u8, attributes: anytype) Writer.Error!void {
        try self.out.writeAll("<" ++ tag);
        inline for (@typeInfo(@TypeOf(attributes)).@"struct".fields) |field| {
            try self.attribute(comptime attributeName(field.name), @field(attributes, field.name));
        }
        try self.out.writeByte('>');
    }

    pub fn close(self: Builder, comptime tag: []const u8) Writer.Error!void {
        try self.out.writeAll("</" ++ tag ++ ">");
    }

    /// A void element: `<img …>`, `<meta …>`.
    pub fn empty(self: Builder, comptime tag: []const u8, attributes: anytype) Writer.Error!void {
        try self.open(tag, attributes);
    }

    /// The common case: one element around one piece of escaped text.
    pub fn element(
        self: Builder,
        comptime tag: []const u8,
        attributes: anytype,
        value: []const u8,
    ) Writer.Error!void {
        try self.open(tag, attributes);
        try self.text(value);
        try self.close(tag);
    }

    pub fn link(self: Builder, href: []const u8, label: []const u8) Writer.Error!void {
        try self.open("a", .{ .href = href });
        try self.text(label);
        try self.close("a");
    }

    fn attribute(self: Builder, comptime name: []const u8, value: anytype) Writer.Error!void {
        switch (@typeInfo(@TypeOf(value))) {
            .optional => {
                if (value) |present| try self.attribute(name, present);
            },
            .bool => if (value) try self.out.writeAll(" " ++ name),
            .int, .comptime_int => try self.out.print(" " ++ name ++ "=\"{d}\"", .{value}),
            else => {
                try self.out.writeAll(" " ++ name ++ "=\"");
                try escape(self.out, value);
                try self.out.writeByte('"');
            },
        }
    }
};

fn attributeName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len]u8 = undefined;
        var length = field.len;
        while (length > 0 and field[length - 1] == '_') length -= 1;
        for (field[0..length], 0..) |byte, at| name[at] = if (byte == '_') '-' else byte;
        const frozen = name;
        return frozen[0..length];
    }
}

const testing_gpa = std.testing.allocator;

fn render(body: anytype) ![]u8 {
    var out: Writer.Allocating = .init(testing_gpa);
    errdefer out.deinit();
    try body(Builder{ .out = &out.writer });
    return out.toOwnedSlice();
}

test "text is escaped and raw is not" {
    const rendered = try render(struct {
        fn body(html: Builder) !void {
            try html.element("p", .{}, "Chêne <b>&</b> \"quote\" 'apostrophe'");
            try html.raw("<hr>");
        }
    }.body);
    defer testing_gpa.free(rendered);

    try std.testing.expectEqualStrings(
        "<p>Chêne &lt;b&gt;&amp;&lt;/b&gt; &quot;quote&quot; &#x27;apostrophe&#x27;</p><hr>",
        rendered,
    );
}

test "attribute names lose their trailing underscore and gain dashes" {
    const rendered = try render(struct {
        fn body(html: Builder) !void {
            try html.open("div", .{ .class_ = "card", .data_root = "../", .aria_label = "x" });
            try html.close("div");
        }
    }.body);
    defer testing_gpa.free(rendered);

    try std.testing.expectEqualStrings(
        "<div class=\"card\" data-root=\"../\" aria-label=\"x\"></div>",
        rendered,
    );
}

test "booleans, integers and nulls each render their own way" {
    const rendered = try render(struct {
        fn body(html: Builder) !void {
            try html.empty("img", .{
                .width = 320,
                .height = @as(?u32, null),
                .loading = "lazy",
                .hidden = true,
                .autofocus = false,
            });
        }
    }.body);
    defer testing_gpa.free(rendered);

    try std.testing.expectEqualStrings(
        "<img width=\"320\" loading=\"lazy\" hidden>",
        rendered,
    );
}

test "an attribute value cannot break out of its quotes" {
    const rendered = try render(struct {
        fn body(html: Builder) !void {
            try html.empty("img", .{ .alt = "a\" onerror=\"alert(1)" });
        }
    }.body);
    defer testing_gpa.free(rendered);

    try std.testing.expectEqualStrings(
        "<img alt=\"a&quot; onerror=&quot;alert(1)\">",
        rendered,
    );
}

test "escaping never leaves a lone ampersand" {
    try std.testing.fuzz({}, fuzzEscape, .{});
}

fn fuzzEscape(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buffer: [256]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];

    var out: Writer.Allocating = .init(testing_gpa);
    defer out.deinit();
    try escape(&out.writer, input);

    // Nothing an escaped run produces can be read as markup or as an attribute
    // delimiter, which is the whole property this function exists for.
    for (out.written()) |byte| try std.testing.expect(byte != '<' and byte != '>' and
        byte != '"' and byte != '\'');
}
