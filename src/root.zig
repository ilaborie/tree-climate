//! Everything the binary and the tests import.
//!
//! Modules are layered and the layering is enforced by review, not by the
//! compiler: pure modules (no filesystem, no subprocess, no global state) come
//! first and may not import anything below them. That boundary is what lets the
//! unit tests run under `std.testing.allocator` in milliseconds.

// Layer 0 — pure, std-only.
pub const cli = @import("cli.zig");
pub const credits = @import("credits.zig");
pub const csv = @import("csv.zig");
pub const licence = @import("licence.zig");
pub const json = @import("json_util.zig");
pub const merge = @import("merge.zig");
pub const model = @import("model.zig");
pub const names = @import("names.zig");
pub const text = @import("text.zig");
pub const pdf = struct {
    pub const xml = @import("pdf/xml.zig");
    pub const table = @import("pdf/table.zig");
};

pub const site = struct {
    pub const catalogue = @import("site/catalogue.zig");
    pub const html = @import("site/html.zig");
    pub const page = @import("site/page.zig");
    pub const search = @import("site/search.zig");
    pub const verify = @import("site/verify.zig");
};

// Layer 1 — the seams onto the outside world.
pub const cache = @import("cache.zig");
pub const exec = @import("exec.zig");
pub const http = @import("http.zig");
pub const net = @import("net.zig");
pub const imgproc = @import("imgproc.zig");
pub const Host = @import("host.zig").Host;

// Layer 2 — one module per subcommand.
pub const cmd = struct {
    pub const credits = @import("cmd/credits.zig");
    pub const enrich = @import("cmd/enrich.zig");
    pub const images = @import("cmd/images.zig");
    pub const extract = @import("cmd/extract.zig");
    pub const site = @import("cmd/site.zig");
};

test {
    _ = cli;
    _ = csv;
    _ = json;
    _ = merge;
    _ = model;
    _ = names;
    _ = text;
    _ = pdf.xml;
    _ = pdf.table;
    _ = credits;
    _ = licence;
    _ = site.catalogue;
    _ = site.html;
    _ = site.page;
    _ = site.search;
    _ = site.verify;
    _ = cache;
    _ = exec;
    _ = http;
    _ = net;
    _ = imgproc;
    _ = cmd.credits;
    _ = cmd.enrich;
    _ = cmd.images;
    _ = cmd.extract;
    _ = cmd.site;
}
