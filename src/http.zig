//! A polite JSON client: per-host rate limiting, retries, and the disk cache.
//!
//! The transport is `curl`, run as a subprocess. That is a deliberate trade:
//! TLS, redirects, compression and timeouts are a mature tool's problem, and
//! everything that is actually ours -- what to cache, what to retry, how long
//! to wait -- stays here in Zig where it can be tested against a fake runner.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Cache = @import("cache.zig").Cache;
const exec = @import("exec.zig");
const Host = @import("host.zig").Host;

/// The Wikimedia APIs require a User-Agent that identifies the caller and gives
/// a way to make contact.
pub const user_agent =
    "tree-climate/0.1 (+https://github.com/ilaborie/tree-climate; ilaborie@gmail.com)";

pub const attempts = 3;
pub const timeout_seconds = 30;

/// Minimum delay between two calls to the same host, in milliseconds.
const delays = [_]struct { host: []const u8, ms: u64 }{
    .{ .host = "api.gbif.org", .ms = 200 },
    .{ .host = "query.wikidata.org", .ms = 1000 },
    .{ .host = "www.wikidata.org", .ms = 300 },
    .{ .host = "fr.wikipedia.org", .ms = 200 },
    .{ .host = "en.wikipedia.org", .ms = 200 },
    .{ .host = "commons.wikimedia.org", .ms = 200 },
    .{ .host = "api.inaturalist.org", .ms = 1000 },
    .{ .host = "upload.wikimedia.org", .ms = 300 },
};
const default_delay_ms = 500;

pub const Error = error{
    /// The call failed after exhausting its retries, or the data was missing
    /// from the cache while offline.
    Unreachable,
};

pub const Param = struct { name: []const u8, value: []const u8 };

pub const Counters = struct {
    calls: usize = 0,
    cache_hits: usize = 0,
    absences: usize = 0,
    failures: usize = 0,
};

pub const Client = struct {
    host: Host,
    cache: Cache,
    /// Forbids every network call: only the cache is read. This is how the
    /// enrichment is replayed and verified without touching a single API.
    offline: bool = false,
    counters: Counters = .{},
    /// Zeroed in tests: the retry policy is what is under test, not the wait.
    backoff_base_ms: u64 = 1000,
    last_call_ns: std.StringHashMapUnmanaged(i96) = .empty,

    pub fn deinit(self: *Client) void {
        self.last_call_ns.deinit(self.host.gpa);
    }

    /// The cached response for `key`, fetching it only on a miss.
    ///
    /// Leaky: the returned value lives in `arena`.
    pub fn cachedLeaky(
        self: *Client,
        arena: Allocator,
        source: []const u8,
        key: []const u8,
        url: []const u8,
        query: []const Param,
        method: Method,
    ) !?std.json.Value {
        if (try self.cache.readLeaky(arena, source, key)) |entry| {
            self.counters.cache_hits += 1;
            return switch (entry) {
                .absent => null,
                .present => |value| value,
            };
        }
        if (self.offline) {
            self.counters.failures += 1;
            std.log.warn("missing from cache while offline: {s}/{s}", .{ source, key });
            return Error.Unreachable;
        }
        const fetched = try self.fetchLeaky(arena, url, query, method);
        try self.cache.write(source, key, fetched);
        return fetched;
    }

    pub const Method = enum { get, post_form };

    /// One JSON call, with the retry policy applied.
    ///
    /// Null means the source answered 404: the page does not exist, which is an
    /// answer and not a failure.
    pub fn fetchLeaky(
        self: *Client,
        arena: Allocator,
        url: []const u8,
        query: []const Param,
        method: Method,
    ) !?std.json.Value {
        if (self.offline) return Error.Unreachable;

        var attempt: u6 = 1;
        while (attempt <= attempts) : (attempt += 1) {
            try self.waitTurn(hostOf(url));

            const response = try self.call(arena, url, query, method);
            switch (response.status) {
                200...299 => {
                    self.counters.calls += 1;
                    return std.json.parseFromSliceLeaky(
                        std.json.Value,
                        arena,
                        response.body,
                        .{},
                    ) catch {
                        // Truncated or non-JSON: worth one more try, since the
                        // alternative is caching nonsense.
                        try self.backOff(attempt);
                        continue;
                    };
                },
                404 => {
                    self.counters.absences += 1;
                    return null;
                },
                429 => {
                    try self.backOff(attempt);
                    continue;
                },
                // Anything else in the 4xx range is our mistake, not a blip:
                // retrying a malformed request just makes it three times.
                400...403, 405...428, 430...499 => {
                    self.counters.failures += 1;
                    std.log.warn("{d} on {s}", .{ response.status, url });
                    return Error.Unreachable;
                },
                else => {
                    if (attempt < attempts) try self.backOff(attempt);
                },
            }
        }

        self.counters.failures += 1;
        std.log.warn("gave up after {d} attempts: {s}", .{ attempts, url });
        return Error.Unreachable;
    }

    const Response = struct { status: u16, body: []const u8 };

    fn call(
        self: *Client,
        arena: Allocator,
        url: []const u8,
        query: []const Param,
        method: Method,
    ) !Response {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{
            "curl",                                           "--silent",
            "--show-error",                                   "--location",
            "--compressed",                                   "--max-time",
            std.fmt.comptimePrint("{d}", .{timeout_seconds}), "--user-agent",
            user_agent,                                       "--header",
            "Accept: application/json",
            // The body may end without a newline and may contain plenty of
            // them, so the status is appended after one and read off the tail.
                                  "--write-out",
            "\n%{http_code}",
        });
        // --get turns the urlencoded pairs into a query string instead of a
        // body, so one code path builds both kinds of request.
        if (method == .get and query.len > 0) try argv.append(arena, "--get");
        for (query) |param| {
            try argv.append(arena, "--data-urlencode");
            try argv.append(arena, try std.fmt.allocPrint(
                arena,
                "{s}={s}",
                .{ param.name, param.value },
            ));
        }
        try argv.append(arena, url);

        const output = try self.host.runner.run(self.host.gpa, self.host.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(64 << 20),
        });
        defer output.deinit(self.host.gpa);

        if (output.exit_code != 0) {
            // curl could not complete the exchange at all: DNS, TLS, timeout.
            // Report it as a server-side problem so the retry loop takes over.
            return .{ .status = 599, .body = "" };
        }
        return splitStatus(try arena.dupe(u8, output.stdout));
    }

    fn waitTurn(self: *Client, host_name: []const u8) !void {
        const wanted_ms = delayFor(host_name);
        const now = std.Io.Timestamp.now(self.host.io, .awake).nanoseconds;
        if (self.last_call_ns.get(host_name)) |previous| {
            const elapsed_ms = @divTrunc(now - previous, std.time.ns_per_ms);
            if (elapsed_ms < wanted_ms) {
                try sleepMs(self.host.io, @intCast(wanted_ms - elapsed_ms));
            }
        }
        try self.last_call_ns.put(
            self.host.gpa,
            host_name,
            std.Io.Timestamp.now(self.host.io, .awake).nanoseconds,
        );
    }

    /// Exponential: two seconds, then four. Long enough to matter to a rate
    /// limiter, short enough that a run still finishes.
    fn backOff(self: *Client, attempt: u6) !void {
        const wait = self.backoff_base_ms * (@as(u64, 1) << attempt);
        if (wait > 0) try sleepMs(self.host.io, wait);
    }
};

fn sleepMs(io: std.Io, milliseconds: u64) !void {
    try std.Io.sleep(io, .{ .nanoseconds = @intCast(milliseconds * std.time.ns_per_ms) }, .awake);
}

/// Splits the body from the status code curl appended after a final newline.
fn splitStatus(stdout: []const u8) Client.Response {
    const at = std.mem.lastIndexOfScalar(u8, stdout, '\n') orelse
        return .{ .status = 0, .body = stdout };
    const status = std.fmt.parseUnsigned(u16, std.mem.trim(
        u8,
        stdout[at + 1 ..],
        &std.ascii.whitespace,
    ), 10) catch return .{ .status = 0, .body = stdout };
    return .{ .status = status, .body = stdout[0..at] };
}

fn delayFor(host_name: []const u8) u64 {
    for (delays) |entry| {
        if (std.mem.eql(u8, entry.host, host_name)) return entry.ms;
    }
    return default_delay_ms;
}

/// The host part of an absolute URL.
fn hostOf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..slash];
}

const testing_gpa = std.testing.allocator;

test "the status code is read off the tail, body newlines and all" {
    const cases = [_]struct { stdout: []const u8, status: u16, body: []const u8 }{
        .{ .stdout = "{\"a\":1}\n200", .status = 200, .body = "{\"a\":1}" },
        .{ .stdout = "line\nline\n404", .status = 404, .body = "line\nline" },
        .{ .stdout = "\n429", .status = 429, .body = "" },
        .{ .stdout = "no status", .status = 0, .body = "no status" },
    };
    for (cases) |case| {
        const response = splitStatus(case.stdout);
        try std.testing.expectEqual(case.status, response.status);
        try std.testing.expectEqualStrings(case.body, response.body);
    }
}

test "delays are per host, with a default for the rest" {
    try std.testing.expectEqual(@as(u64, 1000), delayFor("query.wikidata.org"));
    try std.testing.expectEqual(@as(u64, 200), delayFor("api.gbif.org"));
    try std.testing.expectEqual(@as(u64, default_delay_ms), delayFor("example.org"));
}

test "the host is taken from the URL, path and query ignored" {
    try std.testing.expectEqualStrings("api.gbif.org", hostOf("https://api.gbif.org/v1/x?y=1"));
    try std.testing.expectEqualStrings("commons.wikimedia.org", hostOf("https://commons.wikimedia.org"));
}

/// A client wired to a scripted runner, so the retry policy can be exercised
/// without a network, a server, or a wait.
fn scripted(host_holder: *Host, fake: *exec.Fake) Client {
    host_holder.runner = fake.runner();
    return .{
        .host = host_holder.*,
        .cache = .{ .host = host_holder.* },
        .backoff_base_ms = 0,
    };
}

fn testHost(arena: Allocator) Host {
    return .{
        .gpa = testing_gpa,
        .arena = arena,
        .io = std.testing.io,
        .root = .cwd(),
        .runner = undefined,
    };
}

/// Silences the warning a giving-up call emits, for the tests that provoke one
/// on purpose. Without this the suite prints diagnostics that look like
/// failures on a run where everything passed.
fn quietly() std.log.Level {
    const previous = std.testing.log_level;
    std.testing.log_level = .err;
    return previous;
}

fn expectPolicy(
    replies: []const exec.Fake.Reply,
    expected_calls: usize,
    check: *const fn (?std.json.Value) anyerror!void,
) !void {
    const previous = quietly();
    defer std.testing.log_level = previous;

    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fake: exec.Fake = .{ .replies = replies };
    defer fake.deinit(testing_gpa);
    var host_holder = testHost(arena);
    var client = scripted(&host_holder, &fake);
    defer client.deinit();

    const outcome = client.fetchLeaky(arena, "https://example.org/x", &.{}, .get);
    try check(outcome catch |failure| {
        try std.testing.expectEqual(Error.Unreachable, failure);
        try std.testing.expectEqual(expected_calls, fake.calls.items.len);
        return;
    });
    try std.testing.expectEqual(expected_calls, fake.calls.items.len);
}

fn expectNull(value: ?std.json.Value) anyerror!void {
    try std.testing.expect(value == null);
}

fn expectObject(value: ?std.json.Value) anyerror!void {
    try std.testing.expect(value != null and value.? == .object);
}

fn expectUnreached(_: ?std.json.Value) anyerror!void {
    return error.ShouldHaveFailed;
}

test "a 404 is an answer: the page does not exist" {
    try expectPolicy(&.{.{ .stdout = "not found\n404" }}, 1, expectNull);
}

test "a server error is retried, and a later success is taken" {
    try expectPolicy(&.{
        .{ .stdout = "\n500" },
        .{ .stdout = "\n503" },
        .{ .stdout = "{\"ok\":true}\n200" },
    }, 3, expectObject);
}

test "a rate limit is retried too" {
    try expectPolicy(&.{
        .{ .stdout = "\n429" },
        .{ .stdout = "{\"ok\":true}\n200" },
    }, 2, expectObject);
}

test "three server errors give up rather than loop" {
    try expectPolicy(&.{
        .{ .stdout = "\n500" },
        .{ .stdout = "\n500" },
        .{ .stdout = "\n500" },
    }, attempts, expectUnreached);
}

test "a 400 is our mistake and is not retried" {
    try expectPolicy(&.{.{ .stdout = "bad request\n400" }}, 1, expectUnreached);
}

test "a curl that cannot connect is treated as a server problem" {
    try expectPolicy(&.{
        .{ .exit_code = 6, .stderr = "could not resolve host" },
        .{ .stdout = "{\"ok\":true}\n200" },
    }, 2, expectObject);
}

test "offline forbids the call outright" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    var fake: exec.Fake = .{ .replies = &.{} };
    defer fake.deinit(testing_gpa);
    var host_holder = testHost(arena_state.allocator());
    var client = scripted(&host_holder, &fake);
    client.offline = true;
    defer client.deinit();

    try std.testing.expectError(
        Error.Unreachable,
        client.fetchLeaky(arena_state.allocator(), "https://example.org/x", &.{}, .get),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}
