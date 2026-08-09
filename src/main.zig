const std = @import("std");
const app = @import("tree_climate");

const usage =
    \\usage: tree-climate <command> [options]
    \\
    \\commands:
    \\  extract   rebuild data/data.json from the CAUE 77 advisory PDF
    \\  enrich    resolve taxa, descriptions and images from open sources
    \\  images    download and recompress the principal image of each species
    \\  credits   render docs/CREDITS.md
    \\  site      generate the static site into site/
    \\
    \\Run `mise tasks` to see how these are wired together.
    \\
;

const Command = enum { extract, enrich, images, credits, site };

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) std.process.fatal("missing command\n\n{s}", .{usage});

    const name = argv[1];
    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help")) {
        var buffer: [usage.len]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
        try stdout.interface.writeAll(usage);
        try stdout.interface.flush();
        return;
    }

    const command = std.meta.stringToEnum(Command, name) orelse
        std.process.fatal("unknown command '{s}'\n\n{s}", .{ name, usage });

    // One arena per stage: the whole in-memory document lives in it and is
    // released in a single call when the stage ends.
    var stage: std.heap.ArenaAllocator = .init(init.gpa);
    defer stage.deinit();

    var system: app.exec.System = .{};
    const host: app.Host = .{
        .gpa = init.gpa,
        .arena = stage.allocator(),
        .io = init.io,
        .root = .cwd(),
        .runner = system.runner(),
    };

    const options = argv[2..];
    switch (command) {
        .credits => try app.cmd.credits.run(host, options),
        .enrich => try app.cmd.enrich.run(host, options),
        .images => try app.cmd.images.run(host, options),
        .extract => try app.cmd.extract.run(host, options),
        .site => try app.cmd.site.run(host, options),
    }
}
