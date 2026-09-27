//! Pure pieces of the dna-repeats command line: argument parsing and output rendering.

const std = @import("std");
const fam = @import("families.zig");
const arrays = @import("arrays.zig");

pub const usage =
    \\Usage: dna-repeats [options] FILE|-|@stdin
    \\Find gap-constrained repeat families (chain_packing rule) in an A/C/G/T corpus.
    \\Input: ASCII whitespace and '-' are removed, letters uppercased; anything else is an error.
    \\
    \\  --min-len N          shortest repeat length (default 8)
    \\  --max-len N          longest repeat length (default 50)
    \\  --max-gap D          most bases between consecutive occurrences (default 400)
    \\  --json               JSON array instead of tab-separated lines
    \\  --arrays             report arrays (merged families, distinct spacers) not families
    \\  --min-copies N       fewest copies in an array (default 3)
    \\  --min-spacer N       fewest bases between array copies (default 0)
    \\  --crispr             CRISPR preset: --arrays, lengths 23..47, spacers 26..64
    \\  -j, --threads N      worker threads (default: one per CPU)
    \\  -o, --output PATH    write results to PATH ('-' or @stdout: stdout; @stderr: stderr)
    \\  --progress           always show progress on stderr
    \\  --no-progress        never show progress (default: only when stderr is a terminal)
    \\  --no-color           no ANSI color on stderr (alias --no-ansi; NO_COLOR is honored)
    \\  --ascii              plain ASCII, no color or Unicode symbols (alias --simple)
    \\  --about              one-line description, version and platform
    \\  -h, --help           this help
    \\
    \\Later options override earlier ones; "--" ends options.
    \\FASTA input: each record is searched separately and named in a leading column;
    \\IUPAC ambiguity codes (N, R, Y, ...) are kept as N, which never matches.
    \\Family TSV: length, count, unit, start offsets (0-based, comma-separated).
    \\Array TSV: start, end (1-based, inclusive), copies, unit length, unit, copy starts (1-based).
    \\
;

/// Three-way switch: auto defers to the terminal (TTY, NO_COLOR); on/off are explicit.
pub const Tristate = enum { auto, on, off };

/// Where results go; stdout is the default.
pub const Output = union(enum) {
    stdout,
    stderr,
    file: []const u8,
};

pub const Config = struct {
    path: []const u8 = "",
    min_len: usize = 8,
    max_len: usize = 50,
    max_gap: usize = 400,
    json: bool = false,
    help: bool = false,
    about: bool = false,
    output: Output = .stdout,
    color: Tristate = .auto,
    progress: Tristate = .auto,
    ascii: bool = false,
    /// Worker threads for the per-length stage; null means one per CPU.
    threads: ?usize = null,
    /// Report called arrays (merged, filtered families) instead of raw families.
    arrays: bool = false,
    min_copies: usize = 3,
    /// Fewest bases between consecutive copies of an array.
    min_spacer: usize = 0,
};

pub const ParseError = error{ MissingValue, BadNumber, UnknownOption, MissingInput, ExtraInput, EmptyLengthRange };

/// PCRE2 bounded quantifiers ({0,n}, {n}) accept at most this value.
const max_quantifier = 65535;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Map an output-path argument to a destination; '-', @stdout and @stderr are stdio.
fn parseOutput(arg: []const u8) Output {
    if (eql(arg, "-") or eql(arg, "@stdout")) return .stdout;
    if (eql(arg, "@stderr")) return .stderr;
    return .{ .file = arg };
}

/// Later options override earlier ones; "--" ends options.
pub fn parseArgs(args: []const []const u8) ParseError!Config {
    var cfg: Config = .{};
    var have_path = false;
    var i: usize = 0;
    var options_done = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (options_done or a.len < 2 or a[0] != '-') {
            if (have_path) return error.ExtraInput;
            cfg.path = a;
            have_path = true;
        } else if (eql(a, "--")) {
            options_done = true;
        } else if (eql(a, "-h") or eql(a, "--help")) {
            cfg.help = true;
        } else if (eql(a, "--about")) {
            cfg.about = true;
        } else if (eql(a, "--json")) {
            cfg.json = true;
        } else if (eql(a, "--progress")) {
            cfg.progress = .on;
        } else if (eql(a, "--no-progress")) {
            cfg.progress = .off;
        } else if (eql(a, "--no-color") or eql(a, "--no-ansi")) {
            cfg.color = .off;
        } else if (eql(a, "--ascii") or eql(a, "--simple")) {
            cfg.ascii = true;
            cfg.color = .off;
        } else if (eql(a, "--arrays")) {
            cfg.arrays = true;
        } else if (eql(a, "--crispr")) {
            // CRISPR preset: repeats 23..47 and spacers 26..64, the published defaults of
            // MinCED (repeats, min spacer) and PILER-CR (max spacer); array output.
            cfg.arrays = true;
            cfg.min_len = 23;
            cfg.max_len = 47;
            cfg.min_spacer = 26; // MinCED's default
            cfg.max_gap = 64; // PILER-CR's default
        } else if (eql(a, "--min-copies") or eql(a, "--min-spacer")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const n = std.fmt.parseInt(usize, args[i], 10) catch return error.BadNumber;
            if (eql(a, "--min-copies")) {
                if (n < 2) return error.BadNumber;
                cfg.min_copies = n;
            } else cfg.min_spacer = n;
        } else if (eql(a, "-j") or eql(a, "--threads")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const n = std.fmt.parseInt(usize, args[i], 10) catch return error.BadNumber;
            if (n == 0) return error.BadNumber;
            cfg.threads = n;
        } else if (eql(a, "-o") or eql(a, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.output = parseOutput(args[i]);
        } else if (eql(a, "--min-len") or eql(a, "--max-len") or eql(a, "--max-gap")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const n = std.fmt.parseInt(usize, args[i], 10) catch return error.BadNumber;
            if (n > max_quantifier) return error.BadNumber;
            if (eql(a, "--min-len")) cfg.min_len = n else if (eql(a, "--max-len")) cfg.max_len = n else cfg.max_gap = n;
        } else {
            return error.UnknownOption;
        }
    }
    if (!have_path and !cfg.help and !cfg.about) return error.MissingInput;
    if (cfg.min_len == 0 or cfg.min_len > cfg.max_len) return error.EmptyLengthRange;
    // The candidate scan uses gap max_gap + (max_len - min_len) in one quantifier.
    if (cfg.max_gap + (cfg.max_len - cfg.min_len) > max_quantifier) return error.BadNumber;
    return cfg;
}

/// The --about line: name, version, purpose and the os-arch this binary was built for.
pub fn writeAbout(w: *std.Io.Writer, version: []const u8, os: []const u8, arch: []const u8) !void {
    try w.print("dna-repeats {s} finds gap-constrained DNA repeat families with PCRE2 capture history ({s}-{s})\n", .{ version, os, arch });
}

pub const Progress = struct {
    done: usize,
    total: usize,
    elapsed_ms: u64,
    /// Terminal columns available; the line never exceeds this.
    width: usize,
    ascii: bool,
};

/// Format a millisecond duration as "4.2s" under a minute, else "3m07s".
fn writeDuration(w: *std.Io.Writer, ms: u64) !void {
    if (ms < 60_000) return w.print("{d}.{d}s", .{ ms / 1000, ms % 1000 / 100 });
    const s = ms / 1000;
    try w.print("{d}m{d:0>2}s", .{ s / 60, s % 60 });
}

/// One progress line (no newline or carriage return): a bar sized to fill `width`,
/// then done/total, percent, elapsed and a linear-rate ETA. Pure: time is injected.
pub fn renderProgress(w: *std.Io.Writer, p: Progress) !void {
    var tail_buf: [96]u8 = undefined;
    var tail: std.Io.Writer = .fixed(&tail_buf);
    const pct = if (p.total == 0) 100 else p.done * 100 / p.total;
    try tail.print(" {d}/{d} {d}% ", .{ p.done, p.total, pct });
    try writeDuration(&tail, p.elapsed_ms);
    if (p.done == 0 or p.total < p.done) {
        try tail.writeAll(" ETA --");
    } else {
        try tail.writeAll(" ETA ");
        try writeDuration(&tail, p.elapsed_ms * (p.total - p.done) / p.done);
    }
    const text = tail.buffered();
    const frame = 2; // the bar's brackets
    const bar = if (p.width > text.len + frame) p.width - text.len - frame else 0;
    const filled = if (p.total == 0) bar else bar * @min(p.done, p.total) / p.total;
    try w.writeAll(if (p.ascii) "[" else "▕");
    for (0..bar) |i| try w.writeAll(if (i < filled) (if (p.ascii) "#" else "█") else (if (p.ascii) "." else "░"));
    try w.writeAll(if (p.ascii) "]" else "▏");
    try w.writeAll(if (bar > 0) text else text[0..@min(text.len, p.width -| frame)]);
}

/// ANSI color on stderr: explicit flags win; auto means a terminal with NO_COLOR unset.
pub fn resolveColor(t: Tristate, is_tty: bool, no_color_env: bool) bool {
    return switch (t) {
        .on => true,
        .off => false,
        .auto => is_tty and !no_color_env,
    };
}

/// Progress on stderr: explicit flags win; auto means stderr is a terminal.
pub fn resolveProgress(t: Tristate, is_tty: bool) bool {
    return switch (t) {
        .on => true,
        .off => false,
        .auto => is_tty,
    };
}

pub const default_columns = 80;

/// Progress-line width: a positive COLUMNS wins (lets scripts and tests pin it), then
/// the terminal's reported width, then 80.
pub fn resolveColumns(columns_env: ?[]const u8, tty_columns: ?usize) usize {
    if (columns_env) |s| {
        const n = std.fmt.parseInt(usize, s, 10) catch 0;
        if (n > 0) return n;
    }
    if (tty_columns) |n| if (n > 0) return n;
    return default_columns;
}

/// One family per line: length, count, unit, positions.
pub fn writeTsv(w: *std.Io.Writer, subject: []const u8, fams: []const fam.Family) !void {
    for (fams) |f| try writeTsvFields(w, subject, f);
}

/// FASTA input: as writeTsv with the record name as a leading column.
pub fn writeTsvRecord(w: *std.Io.Writer, record: []const u8, subject: []const u8, fams: []const fam.Family) !void {
    for (fams) |f| {
        try w.print("{s}\t", .{record});
        try writeTsvFields(w, subject, f);
    }
}

fn writeTsvFields(w: *std.Io.Writer, subject: []const u8, f: fam.Family) !void {
    try w.print("{d}\t{d}\t{s}\t", .{ f.len, f.positions.len, subject[f.positions[0]..][0..f.len] });
    for (f.positions, 0..) |p, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", p });
    try w.writeAll("\n");
}

/// One array per line, 1-based inclusive like GFF and CRISPRCasdb:
/// [record,] start, end, copies, unit length, unit, comma-separated copy starts.
pub fn writeArraysTsv(w: *std.Io.Writer, record: ?[]const u8, subject: []const u8, list: []const arrays.Array) !void {
    for (list) |a| {
        if (record) |r| try w.print("{s}\t", .{r});
        try w.print("{d}\t{d}\t{d}\t{d}\t{s}\t", .{ a.start + 1, a.end, a.copies, a.unit_len, subject[a.unit_pos..][0..a.unit_len] });
        for (a.positions, 0..) |p, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", p + 1 });
        try w.writeAll("\n");
    }
}

/// One array as a JSON object (no trailing separator); "record" only for FASTA input.
pub fn writeJsonArray(w: *std.Io.Writer, record: ?[]const u8, subject: []const u8, a: arrays.Array) !void {
    try w.writeAll("{");
    if (record) |r| {
        try w.writeAll("\"record\":");
        try std.json.Stringify.encodeJsonString(r, .{}, w);
        try w.writeAll(",");
    }
    try w.print("\"start\":{d},\"end\":{d},\"copies\":{d},\"unit_length\":{d},\"unit\":\"{s}\",\"positions\":[", .{ a.start + 1, a.end, a.copies, a.unit_len, subject[a.unit_pos..][0..a.unit_len] });
    for (a.positions, 0..) |p, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", p + 1 });
    try w.writeAll("]}");
}

/// Emit one family as a JSON object (no trailing separator).
pub fn writeJsonFamily(w: *std.Io.Writer, subject: []const u8, f: fam.Family) !void {
    try w.writeAll("{");
    try writeJsonFields(w, subject, f);
}

/// FASTA input: as writeJsonFamily with a leading, JSON-escaped "record" field.
pub fn writeJsonFamilyRecord(w: *std.Io.Writer, record: []const u8, subject: []const u8, f: fam.Family) !void {
    try w.writeAll("{\"record\":");
    try std.json.Stringify.encodeJsonString(record, .{}, w);
    try w.writeAll(",");
    try writeJsonFields(w, subject, f);
}

fn writeJsonFields(w: *std.Io.Writer, subject: []const u8, f: fam.Family) !void {
    try w.print("\"length\":{d},\"count\":{d},\"unit\":\"{s}\",\"positions\":[", .{ f.len, f.positions.len, subject[f.positions[0]..][0..f.len] });
    for (f.positions, 0..) |p, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", p });
    try w.writeAll("]}");
}

const testing = std.testing;

test "parses options in any order, later wins" {
    const cfg = try parseArgs(&.{ "--max-gap", "10", "in.txt", "--min-len", "3", "--max-gap", "20", "--json" });
    try testing.expectEqualStrings("in.txt", cfg.path);
    try testing.expectEqual(@as(usize, 3), cfg.min_len);
    try testing.expectEqual(@as(usize, 20), cfg.max_gap);
    try testing.expectEqual(@as(usize, 50), cfg.max_len);
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

test "--about and output destinations" {
    try testing.expect((try parseArgs(&.{"--about"})).about);
    try testing.expectEqual(Output.stdout, (try parseArgs(&.{"x"})).output);
    try testing.expectEqual(Output.stdout, (try parseArgs(&.{ "x", "-o", "-" })).output);
    try testing.expectEqual(Output.stdout, (try parseArgs(&.{ "x", "--output", "@stdout" })).output);
    try testing.expectEqual(Output.stderr, (try parseArgs(&.{ "x", "-o", "@stderr" })).output);
    const cfg = try parseArgs(&.{ "x", "-o", "a.tsv", "--output", "out dir/b.tsv" });
    try testing.expectEqualStrings("out dir/b.tsv", cfg.output.file);
    try testing.expectError(error.MissingValue, parseArgs(&.{ "x", "-o" }));
}

test "--threads: default auto, positive counts, later wins" {
    try testing.expectEqual(@as(?usize, null), (try parseArgs(&.{"x"})).threads);
    try testing.expectEqual(@as(?usize, 4), (try parseArgs(&.{ "x", "--threads", "4" })).threads);
    try testing.expectEqual(@as(?usize, 1), (try parseArgs(&.{ "x", "-j", "8", "-j", "1" })).threads);
    try testing.expectError(error.BadNumber, parseArgs(&.{ "x", "--threads", "0" }));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "x", "-j" }));
}

test "--arrays, --crispr preset, and array tuning; later wins" {
    const d = try parseArgs(&.{"x"});
    try testing.expect(!d.arrays);
    try testing.expectEqual(@as(usize, 3), d.min_copies);
    try testing.expectEqual(@as(usize, 0), d.min_spacer);
    try testing.expect((try parseArgs(&.{ "x", "--arrays" })).arrays);
    const c = try parseArgs(&.{ "x", "--crispr" });
    try testing.expect(c.arrays);
    try testing.expectEqual(@as(usize, 23), c.min_len);
    try testing.expectEqual(@as(usize, 47), c.max_len);
    try testing.expectEqual(@as(usize, 26), c.min_spacer);
    try testing.expectEqual(@as(usize, 64), c.max_gap);
    // Options after the preset override it; options before it are overridden.
    const o = try parseArgs(&.{ "x", "--min-len", "30", "--crispr", "--max-gap", "90", "--min-copies", "2", "--min-spacer", "15" });
    try testing.expectEqual(@as(usize, 23), o.min_len);
    try testing.expectEqual(@as(usize, 90), o.max_gap);
    try testing.expectEqual(@as(usize, 2), o.min_copies);
    try testing.expectEqual(@as(usize, 15), o.min_spacer);
    try testing.expectError(error.BadNumber, parseArgs(&.{ "x", "--min-copies", "1" }));
}

test "length and gap bounds: min <= max, and within PCRE2's 65535 quantifier limit" {
    try testing.expectError(error.EmptyLengthRange, parseArgs(&.{ "x", "--min-len", "30", "--max-len", "20" }));
    try testing.expectError(error.EmptyLengthRange, parseArgs(&.{ "x", "--min-len", "0" }));
    try testing.expectError(error.BadNumber, parseArgs(&.{ "x", "--max-len", "65536" }));
    try testing.expectError(error.BadNumber, parseArgs(&.{ "x", "--max-gap", "65536" }));
    try testing.expectEqual(@as(usize, 65535), (try parseArgs(&.{ "x", "--max-gap", "65535", "--min-len", "8", "--max-len", "8" })).max_gap);
    // The candidate scan widens the gap by max_len - min_len; that sum must fit too.
    try testing.expectError(error.BadNumber, parseArgs(&.{ "x", "--max-gap", "65535", "--min-len", "8", "--max-len", "9" }));
    // Checked after all options, so order does not matter.
    try testing.expectEqual(@as(usize, 60), (try parseArgs(&.{ "x", "--min-len", "55", "--max-len", "60" })).max_len);
}

test "display switches: later wins" {
    const d = try parseArgs(&.{"x"});
    try testing.expectEqual(Tristate.auto, d.color);
    try testing.expectEqual(Tristate.auto, d.progress);
    try testing.expect(!d.ascii);
    try testing.expectEqual(Tristate.off, (try parseArgs(&.{ "x", "--no-color" })).color);
    try testing.expectEqual(Tristate.off, (try parseArgs(&.{ "x", "--no-ansi" })).color);
    try testing.expectEqual(Tristate.on, (try parseArgs(&.{ "x", "--no-progress", "--progress" })).progress);
    try testing.expectEqual(Tristate.off, (try parseArgs(&.{ "x", "--progress", "--no-progress" })).progress);
    // --ascii/--simple also drop ANSI.
    const s = try parseArgs(&.{ "x", "--simple" });
    try testing.expect(s.ascii);
    try testing.expectEqual(Tristate.off, s.color);
    try testing.expect((try parseArgs(&.{ "x", "--ascii" })).ascii);
}

test "--about is one line with version and platform" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeAbout(&w, "1.2.3", "linux", "x86_64");
    const line = w.buffered();
    try testing.expect(std.mem.startsWith(u8, line, "dna-repeats 1.2.3 "));
    try testing.expect(std.mem.endsWith(u8, line, " (linux-x86_64)\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

/// Display columns of UTF-8 text without ANSI escapes (one column per code point).
fn displayWidth(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        if (s[i] & 0xc0 != 0x80) cols += 1;
        i += 1;
    }
    return cols;
}

test "progress line: counts, percent, ETA and width" {
    var buf: [512]u8 = undefined;
    inline for (.{ false, true }) |ascii| {
        inline for (.{ 40, 60, 100 }) |width| {
            var w: std.Io.Writer = .fixed(&buf);
            try renderProgress(&w, .{ .done = 10, .total = 40, .elapsed_ms = 2000, .width = width, .ascii = ascii });
            const line = w.buffered();
            try testing.expect(std.mem.indexOf(u8, line, "10/40") != null);
            try testing.expect(std.mem.indexOf(u8, line, "25%") != null);
            // 10 of 40 in 2.0s leaves 30 at the same rate: 6.0s.
            try testing.expect(std.mem.indexOf(u8, line, "ETA 6.0s") != null);
            try testing.expect(displayWidth(line) <= width);
            if (ascii) for (line) |b| try testing.expect(b < 0x80);
        }
    }
    var w: std.Io.Writer = .fixed(&buf);
    try renderProgress(&w, .{ .done = 0, .total = 5, .elapsed_ms = 0, .width = 80, .ascii = true });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "ETA --") != null);
}

test "auto switches resolve against the terminal, explicit ones win" {
    // Classifier over the whole input space: (tristate, tty, NO_COLOR set).
    for ([_]Tristate{ .auto, .on, .off }) |t| {
        for ([_]bool{ false, true }) |tty| {
            for ([_]bool{ false, true }) |no_color| {
                const want_color = switch (t) {
                    .on => true,
                    .off => false,
                    .auto => tty and !no_color,
                };
                try testing.expectEqual(want_color, resolveColor(t, tty, no_color));
                const want_progress = switch (t) {
                    .on => true,
                    .off => false,
                    .auto => tty,
                };
                try testing.expectEqual(want_progress, resolveProgress(t, tty));
            }
        }
    }
}

test "terminal width: COLUMNS, then the terminal, then 80" {
    try testing.expectEqual(@as(usize, 132), resolveColumns("132", 100));
    try testing.expectEqual(@as(usize, 100), resolveColumns(null, 100));
    try testing.expectEqual(@as(usize, 100), resolveColumns("wide", 100));
    try testing.expectEqual(@as(usize, 100), resolveColumns("0", 100));
    try testing.expectEqual(@as(usize, 80), resolveColumns(null, null));
    try testing.expectEqual(@as(usize, 80), resolveColumns(null, 0));
}

test "FASTA records add a leading record column and a record field" {
    var positions = [_]usize{ 0, 2, 4 };
    const fams = [_]fam.Family{.{ .len = 2, .positions = &positions }};
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTsvRecord(&w, "chr1", "ACACAC", &fams);
    try testing.expectEqualStrings("chr1\t2\t3\tAC\t0,2,4\n", w.buffered());
    w = .fixed(&buf);
    try writeJsonFamilyRecord(&w, "chr \"1\"", "ACACAC", fams[0]);
    try testing.expectEqualStrings("{\"record\":\"chr \\\"1\\\"\",\"length\":2,\"count\":3,\"unit\":\"AC\",\"positions\":[0,2,4]}", w.buffered());
}

test "array rendering: 1-based inclusive coordinates, copy positions, optional record" {
    var at = [_]usize{ 2, 4, 8 };
    const a = [_]arrays.Array{.{ .start = 2, .end = 10, .copies = 3, .unit_len = 2, .unit_pos = 2, .positions = &at }};
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeArraysTsv(&w, null, "TTACACACTT", &a);
    try testing.expectEqualStrings("3\t10\t3\t2\tAC\t3,5,9\n", w.buffered());
    w = .fixed(&buf);
    try writeArraysTsv(&w, "chr1", "TTACACACTT", &a);
    try testing.expectEqualStrings("chr1\t3\t10\t3\t2\tAC\t3,5,9\n", w.buffered());
    w = .fixed(&buf);
    try writeJsonArray(&w, "chr1", "TTACACACTT", a[0]);
    try testing.expectEqualStrings("{\"record\":\"chr1\",\"start\":3,\"end\":10,\"copies\":3,\"unit_length\":2,\"unit\":\"AC\",\"positions\":[3,5,9]}", w.buffered());
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
