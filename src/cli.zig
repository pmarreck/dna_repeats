//! Pure pieces of the dna-repeats command line: argument parsing and output rendering.

const std = @import("std");
const fam = @import("families.zig");

pub const usage =
    \\Usage: dna-repeats [options] FILE|-
    \\Find gap-constrained repeat families (chain_packing rule) in an A/C/G/T corpus.
    \\Input: ASCII whitespace and '-' are removed, letters uppercased; anything else is an error.
    \\
    \\  --min-len N   shortest repeat length (default 8)
    \\  --max-len N   longest repeat length (default: longest non-overlapping repeat)
    \\  --max-gap D   most bases between consecutive occurrences (default 400)
    \\  --json        JSON array instead of tab-separated lines
    \\  -h, --help    this help
    \\
    \\TSV columns: length, count, unit, comma-separated start offsets (0-based, normalized).
    \\
;

pub const Config = struct {
    path: []const u8 = "",
    min_len: usize = 8,
    max_len: ?usize = null,
    max_gap: usize = 400,
    json: bool = false,
    help: bool = false,
};

pub const ParseError = error{ MissingValue, BadNumber, UnknownOption, MissingInput, ExtraInput };

/// Later options override earlier ones; "--" ends options.
pub fn parseArgs(args: []const []const u8) ParseError!Config {
    var cfg: Config = .{};
    var have_path = false;
    var i: usize = 0;
    var options_done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!options_done and std.mem.eql(u8, a, "--")) {
            options_done = true;
        } else if (!options_done and (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help"))) {
            cfg.help = true;
        } else if (!options_done and std.mem.eql(u8, a, "--json")) {
            cfg.json = true;
        } else if (!options_done and (std.mem.eql(u8, a, "--min-len") or std.mem.eql(u8, a, "--max-len") or std.mem.eql(u8, a, "--max-gap"))) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const n = std.fmt.parseInt(usize, args[i], 10) catch return error.BadNumber;
            if (std.mem.eql(u8, a, "--min-len")) cfg.min_len = n else if (std.mem.eql(u8, a, "--max-len")) cfg.max_len = n else cfg.max_gap = n;
        } else if (!options_done and a.len > 1 and a[0] == '-') {
            return error.UnknownOption;
        } else {
            if (have_path) return error.ExtraInput;
            cfg.path = a;
            have_path = true;
        }
    }
    if (!have_path and !cfg.help) return error.MissingInput;
    return cfg;
}

/// One family per line: length, count, unit, positions.
pub fn writeTsv(w: *std.Io.Writer, subject: []const u8, fams: []const fam.Family) !void {
    for (fams) |f| {
        try w.print("{d}\t{d}\t{s}\t", .{ f.len, f.positions.len, subject[f.positions[0]..][0..f.len] });
        for (f.positions, 0..) |p, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", p });
        try w.writeAll("\n");
    }
}

/// Emit one family as a JSON object (no trailing separator).
pub fn writeJsonFamily(w: *std.Io.Writer, subject: []const u8, f: fam.Family) !void {
    try w.print("{{\"length\":{d},\"count\":{d},\"unit\":\"{s}\",\"positions\":[", .{ f.len, f.positions.len, subject[f.positions[0]..][0..f.len] });
    for (f.positions, 0..) |p, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", p });
    try w.writeAll("]}");
}

const testing = std.testing;

test "parses options in any order, later wins" {
    const cfg = try parseArgs(&.{ "--max-gap", "10", "in.txt", "--min-len", "3", "--max-gap", "20", "--json" });
    try testing.expectEqualStrings("in.txt", cfg.path);
    try testing.expectEqual(@as(usize, 3), cfg.min_len);
    try testing.expectEqual(@as(usize, 20), cfg.max_gap);
    try testing.expectEqual(@as(?usize, null), cfg.max_len);
    try testing.expect(cfg.json);
}

test "stdin, paths with spaces, and -- end of options" {
    try testing.expectEqualStrings("-", (try parseArgs(&.{"-"})).path);
    try testing.expectEqualStrings("my corpus.txt", (try parseArgs(&.{"my corpus.txt"})).path);
    try testing.expectEqualStrings("--json", (try parseArgs(&.{ "--", "--json" })).path);
}

test "argument errors are classified" {
    try testing.expectError(error.MissingInput, parseArgs(&.{}));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "x", "--min-len" }));
    try testing.expectError(error.BadNumber, parseArgs(&.{ "x", "--max-gap", "lots" }));
    try testing.expectError(error.UnknownOption, parseArgs(&.{ "x", "--frobnicate" }));
    try testing.expectError(error.ExtraInput, parseArgs(&.{ "a", "b" }));
    try testing.expect((try parseArgs(&.{"--help"})).help);
}

test "TSV and JSON rendering" {
    var positions = [_]usize{ 0, 2, 4 };
    const fams = [_]fam.Family{.{ .len = 2, .positions = &positions }};
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTsv(&w, "ACACAC", &fams);
    try testing.expectEqualStrings("2\t3\tAC\t0,2,4\n", w.buffered());
    w = .fixed(&buf);
    try writeJsonFamily(&w, "ACACAC", fams[0]);
    try testing.expectEqualStrings("{\"length\":2,\"count\":3,\"unit\":\"AC\",\"positions\":[0,2,4]}", w.buffered());
}
