//! A CSV writer matching Python's `csv.DictWriter` defaults, because the files
//! it produced are the reference: CRLF line endings, and a field quoted only
//! when it contains a comma, a quote or a line break.

const std = @import("std");

/// Multi-valued cells are joined with a vertical bar, which needs no escaping
/// and stays readable in a spreadsheet.
pub const value_separator = "|";

pub const Writer = struct {
    out: *std.Io.Writer,
    /// Semicolon for the files meant to be edited by hand in a spreadsheet that
    /// expects it; comma everywhere else.
    delimiter: u8 = ',',
    column: usize = 0,

    pub fn field(self: *Writer, value: []const u8) std.Io.Writer.Error!void {
        if (self.column > 0) try self.out.writeByte(self.delimiter);
        self.column += 1;

        const specials = [_]u8{ self.delimiter, '"', '\r', '\n' };
        if (std.mem.indexOfAny(u8, value, &specials) == null) return self.out.writeAll(value);

        try self.out.writeByte('"');
        for (value) |byte| {
            if (byte == '"') try self.out.writeByte('"');
            try self.out.writeByte(byte);
        }
        try self.out.writeByte('"');
    }

    pub fn fields(self: *Writer, values: []const []const u8) std.Io.Writer.Error!void {
        for (values) |value| try self.field(value);
    }

    /// The values joined by `value_separator`, as one field.
    pub fn joined(
        self: *Writer,
        gpa: std.mem.Allocator,
        values: []const []const u8,
    ) !void {
        const text = try std.mem.join(gpa, value_separator, values);
        defer gpa.free(text);
        try self.field(text);
    }

    pub fn endRow(self: *Writer) std.Io.Writer.Error!void {
        try self.out.writeAll("\r\n");
        self.column = 0;
    }
};

const testing_gpa = std.testing.allocator;

fn renderRow(values: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing_gpa);
    errdefer out.deinit();
    var writer: Writer = .{ .out = &out.writer };
    try writer.fields(values);
    try writer.endRow();
    return out.toOwnedSlice();
}

test "fields are quoted only when they have to be" {
    const row = try renderRow(&.{ "Abies concolor", "Sapin du Colorado, sapin bleu", "", "25" });
    defer testing_gpa.free(row);
    try std.testing.expectEqualStrings(
        "Abies concolor,\"Sapin du Colorado, sapin bleu\",,25\r\n",
        row,
    );
}

test "a quote inside a field is doubled" {
    const row = try renderRow(&.{"say \"hi\""});
    defer testing_gpa.free(row);
    try std.testing.expectEqualStrings("\"say \"\"hi\"\"\"\r\n", row);
}

test "a newline forces quoting" {
    const row = try renderRow(&.{"a\nb"});
    defer testing_gpa.free(row);
    try std.testing.expectEqualStrings("\"a\nb\"\r\n", row);
}

test "multi-valued cells join with a bar" {
    var out: std.Io.Writer.Allocating = .init(testing_gpa);
    defer out.deinit();
    var writer: Writer = .{ .out = &out.writer };

    try writer.joined(testing_gpa, &.{ "acide", "neutre", "basique" });
    try writer.endRow();

    try std.testing.expectEqualStrings("acide|neutre|basique\r\n", out.written());
}
