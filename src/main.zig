//! dna-repeats: I/O adapter around the pure finder, normalizer and renderers.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const norm = @import("normalize.zig");
const finder = @import("finder.zig");
const fam = @import("families.zig");

const default_columns = 80;

/// Wrap `text` in an SGR sequence when color is on.
fn paint(w: *std.Io.Writer, color: bool, sgr: []const u8, text: []const u8) !void {
    if (color) try w.print("\x1b[{s}m{s}\x1b[0m", .{ sgr, text }) else try w.writeAll(text);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var err_buf: [1024]u8 = undefined;
    const stderr_file = std.Io.File.stderr();
    var err_writer = stderr_file.writer(io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    if (comptime builtin.mode == .Debug) {
        if (env.get("MUTE_DEBUG_STATUS") == null) try stderr.writeAll("\x1b[33mDEBUG BUILD\x1b[0m\n");
    }

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try init.arena.allocator().alloc([]const u8, argv.len -| 1);
    for (args, argv[1..]) |*a, s| a.* = s;
    const cfg = cli.parseArgs(args) catch |e| {
        try stderr.print("dna-repeats: {s}\n{s}", .{ @errorName(e), cli.usage });
        return 2;
    };

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file: ?std.Io.File = null;
    defer if (out_file) |f| f.close(io);
    var out_writer = switch (cfg.output) {
        .file => |path| blk: {
            const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |e| {
                try stderr.print("dna-repeats: cannot create {s}: {s}\n", .{ path, @errorName(e) });
                return 1;
            };
            out_file = f;
            break :blk f.writer(io, &out_buf);
        },
        else => std.Io.File.stdout().writer(io, &out_buf),
    };
    const out = if (cfg.output == .stderr) stderr else &out_writer.interface;

    if (cfg.help or cfg.about) {
        if (cfg.help) try out.writeAll(cli.usage) else try cli.writeAbout(out, build_options.version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch));
        try out.flush();
        return 0;
    }

    const stderr_tty = stderr_file.isTty(io) catch false;
    const no_color_env = if (env.get("NO_COLOR")) |v| v.len > 0 else false;
    const color = cli.resolveColor(cfg.color, stderr_tty, no_color_env);
    // Results written to stderr would be interleaved with the progress line.
    const progress = cfg.output != .stderr and cli.resolveProgress(cfg.progress, stderr_tty);
    const columns = if (env.get("COLUMNS")) |c| std.fmt.parseInt(usize, c, 10) catch default_columns else default_columns;

    const raw = if (std.mem.eql(u8, cfg.path, "-") or std.mem.eql(u8, cfg.path, "@stdin")) blk: {
        var in_buf: [64 * 1024]u8 = undefined;
        var in_reader = std.Io.File.stdin().reader(io, &in_buf);
        break :blk try in_reader.interface.allocRemaining(gpa, .unlimited);
    } else std.Io.Dir.cwd().readFileAlloc(io, cfg.path, gpa, .unlimited) catch |e| {
        try stderr.print("dna-repeats: cannot read {s}: {s}\n", .{ cfg.path, @errorName(e) });
        return 1;
    };
    defer gpa.free(raw);
    const clean_buf = try gpa.alloc(u8, raw.len);
    defer gpa.free(clean_buf);
    var diag: norm.Diagnostic = .{};
    const subject = norm.normalize(raw, clean_buf, &diag) catch {
        try stderr.print("dna-repeats: invalid byte 0x{x:0>2} at input offset {d}\n", .{ diag.byte, diag.offset });
        return 1;
    };

    // Default bound: no family can be longer than the longest non-overlapping repeat.
    const max_len = cfg.max_len orelse fam.longestNonOverlappingRepeat(subject);
    var num: [64]u8 = undefined;
    try paint(stderr, color, "1", try std.fmt.bufPrint(&num, "{d}", .{subject.len}));
    try stderr.print(" bases; lengths {d}..{d}; max gap {d}\n", .{ cfg.min_len, max_len, cfg.max_gap });
    try stderr.flush();

    if (cfg.json) try out.writeAll("[");
    var first = true;
    var total: usize = 0;
    const lengths = if (max_len >= cfg.min_len and max_len > 0) max_len - @max(cfg.min_len, 1) + 1 else 0;
    const started = std.Io.Clock.awake.now(io);
    // One wide-gap scan finds every offset that can start a chain at any length;
    // each length then probes only those offsets.
    const starts = try finder.candidateStarts(gpa, subject, cfg.min_len, max_len, cfg.max_gap);
    defer gpa.free(starts);
    var len = max_len;
    var done: usize = 0;
    while (len >= cfg.min_len and len > 0) : (len -= 1) {
        if (progress) {
            try stderr.writeAll("\r");
            try cli.renderProgress(stderr, .{
                .done = done,
                .total = lengths,
                .elapsed_ms = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()),
                .width = columns -| 1,
                .ascii = cfg.ascii,
            });
            try stderr.flush();
        }
        const f = try finder.Finder.initAnchored(len, cfg.max_gap);
        defer f.deinit();
        const fams = try f.familiesAt(gpa, subject, starts);
        defer fam.freeFamilies(gpa, fams);
        total += fams.len;
        if (cfg.json) {
            for (fams) |one| {
                try out.writeAll(if (first) "\n" else ",\n");
                first = false;
                try cli.writeJsonFamily(out, subject, one);
            }
        } else try cli.writeTsv(out, subject, fams);
        done += 1;
    }
    if (cfg.json) try out.writeAll("\n]\n");
    try out.flush();
    if (progress) {
        // Blank the progress line; plain spaces keep --no-color output free of ANSI.
        try stderr.writeAll("\r");
        try stderr.splatByteAll(' ', columns -| 1);
        try stderr.writeAll("\r");
    }
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    try paint(stderr, color, "1", try std.fmt.bufPrint(&num, "{d}", .{total}));
    try stderr.print(" families in {d} ms\n", .{elapsed.toMilliseconds()});
    return 0;
}
