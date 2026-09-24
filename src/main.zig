//! dna-repeats: I/O adapter around the pure finder, normalizer and renderers.

const std = @import("std");
const cli = @import("cli.zig");
const norm = @import("normalize.zig");
const finder = @import("finder.zig");
const fam = @import("families.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var err_buf: [1024]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cfg = cli.parseArgs(argv[1..]) catch |e| {
        try stderr.print("dna-repeats: {s}\n{s}", .{ @errorName(e), cli.usage });
        return 2;
    };
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;
    if (cfg.help) {
        try out.writeAll(cli.usage);
        try out.flush();
        return 0;
    }

    const raw = if (std.mem.eql(u8, cfg.path, "-") or std.mem.eql(u8, cfg.path, "@stdin")) blk: {
        var in_buf: [64 * 1024]u8 = undefined;
        var in_reader = std.Io.File.stdin().reader(io, &in_buf);
        break :blk try in_reader.interface.allocRemaining(gpa, .unlimited);
    } else try std.Io.Dir.cwd().readFileAlloc(io, cfg.path, gpa, .unlimited);
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
    try stderr.print("{d} bases; lengths {d}..{d}; max gap {d}\n", .{ subject.len, cfg.min_len, max_len, cfg.max_gap });
    if (cfg.json) try out.writeAll("[");
    var first = true;
    var total: usize = 0;
    const started = std.Io.Clock.awake.now(io);
    var len = max_len;
    while (len >= cfg.min_len and len > 0) : (len -= 1) {
        const f = try finder.Finder.init(len, cfg.max_gap);
        defer f.deinit();
        const fams = try f.families(gpa, subject);
        defer fam.freeFamilies(gpa, fams);
        total += fams.len;
        if (cfg.json) {
            for (fams) |one| {
                try out.writeAll(if (first) "\n" else ",\n");
                first = false;
                try cli.writeJsonFamily(out, subject, one);
            }
        } else try cli.writeTsv(out, subject, fams);
    }
    if (cfg.json) try out.writeAll("\n]\n");
    try out.flush();
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    try stderr.print("{d} families in {d} ms\n", .{ total, elapsed.toMilliseconds() });
    return 0;
}
