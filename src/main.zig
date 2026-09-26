//! dna-repeats: I/O adapter around the pure finder, normalizer and renderers.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const norm = @import("normalize.zig");
const finder = @import("finder.zig");
const fam = @import("families.zig");

/// Terminal width as the OS reports it (console buffer on Windows, TIOCGWINSZ elsewhere),
/// mirroring std.Progress; null when the query fails.
fn terminalColumns(io: std.Io, file: std.Io.File) ?usize {
    if (comptime builtin.os.tag == .windows) {
        var info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
        return switch (info.operate(io, file) catch return null) {
            .SUCCESS => @intCast(info.Data.dwWindowSize.X),
            else => null,
        };
    }
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const op = io.operate(.{ .device_io_control = .{ .file = file, .code = std.posix.T.IOCGWINSZ, .arg = &ws } }) catch return null;
    return if (op.device_io_control >= 0) ws.col else null;
}

/// Wrap `text` in an SGR sequence when color is on.
fn paint(w: *std.Io.Writer, color: bool, sgr: []const u8, text: []const u8) !void {
    if (color) try w.print("\x1b[{s}m{s}\x1b[0m", .{ sgr, text }) else try w.writeAll(text);
}

/// Adapts the finder's progress hook (called on this thread only) to the pure renderer.
/// A write error only loses a progress frame, so it is ignored.
const ProgressPainter = struct {
    w: *std.Io.Writer,
    io: std.Io,
    started: std.Io.Timestamp,
    width: usize,
    ascii: bool,

    fn paint(self: *ProgressPainter, done: usize, total: usize) void {
        const elapsed = self.started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
        self.w.writeAll("\r") catch return;
        cli.renderProgress(self.w, .{ .done = done, .total = total, .elapsed_ms = @intCast(elapsed), .width = self.width, .ascii = self.ascii }) catch return;
        self.w.flush() catch return;
    }

    fn step(ctx: *anyopaque, done: usize, total: usize) void {
        const self: *ProgressPainter = @ptrCast(@alignCast(ctx));
        self.paint(done, total);
    }

    fn hook(self: *ProgressPainter) finder.StepFn {
        return .{ .ctx = self, .step = step };
    }
};

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
    const columns = cli.resolveColumns(env.get("COLUMNS"), if (stderr_tty) terminalColumns(io, stderr_file) else null);

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
    // FASTA when the first non-whitespace byte is '>'; otherwise one plain, strict sequence.
    const trimmed = std.mem.trimStart(u8, raw, " \t\r\n");
    const is_fasta = trimmed.len > 0 and trimmed[0] == '>';
    var single: [1]norm.Record = undefined;
    const records: []const norm.Record = if (is_fasta) norm.parseFasta(gpa, raw, clean_buf, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.MissingHeader => {
            try stderr.print("dna-repeats: sequence before the first FASTA header at input offset {d}\n", .{diag.offset});
            return 1;
        },
        error.InvalidBase => {
            try stderr.print("dna-repeats: invalid byte 0x{x:0>2} at input offset {d}\n", .{ diag.byte, diag.offset });
            return 1;
        },
    } else blk: {
        single[0] = .{ .name = "", .seq = norm.normalize(raw, clean_buf, &diag) catch {
            try stderr.print("dna-repeats: invalid byte 0x{x:0>2} at input offset {d}\n", .{ diag.byte, diag.offset });
            return 1;
        } };
        break :blk &single;
    };
    defer if (is_fasta) gpa.free(records);

    var num: [64]u8 = undefined;
    var bases: usize = 0;
    for (records) |r| bases += r.seq.len;
    try paint(stderr, color, "1", try std.fmt.bufPrint(&num, "{d}", .{bases}));
    if (is_fasta) try stderr.print(" bases in {d} records", .{records.len}) else try stderr.writeAll(" bases");
    // Default bound: no family can be longer than the longest non-overlapping repeat.
    if (cfg.max_len) |m| try stderr.print("; lengths {d}..{d}", .{ cfg.min_len, m }) else if (is_fasta) try stderr.print("; lengths {d}..auto", .{cfg.min_len}) else try stderr.print("; lengths {d}..{d}", .{ cfg.min_len, fam.longestNonOverlappingRepeat(records[0].seq) });
    try stderr.print("; max gap {d}\n", .{cfg.max_gap});
    try stderr.flush();

    if (cfg.json) try out.writeAll("[");
    var first = true;
    var total: usize = 0;
    const started = std.Io.Clock.awake.now(io);
    var painter: ProgressPainter = .{ .w = stderr, .io = io, .started = started, .width = columns -| 1, .ascii = cfg.ascii };
    for (records) |rec| {
        const subject = rec.seq;
        const max_len = cfg.max_len orelse fam.longestNonOverlappingRepeat(subject);
        const lengths = if (max_len >= cfg.min_len and max_len > 0) max_len - @max(cfg.min_len, 1) + 1 else 0;
        // One wide-gap scan finds every offset that can start a chain at any length;
        // each length then probes only those offsets, lengths spread over worker threads.
        // -j is honored as given; the automatic count stays single-threaded for small inputs.
        const threads = cfg.threads orelse if (subject.len < finder.parallel_min_offsets) 1 else (std.Thread.getCpuCount() catch 1);
        const starts = try finder.candidateStartsParallel(gpa, subject, cfg.min_len, max_len, cfg.max_gap, .{ .threads = threads });
        defer gpa.free(starts);
        if (progress) painter.paint(0, lengths);
        var results = try finder.familiesByLength(gpa, subject, starts, cfg.min_len, max_len, cfg.max_gap, threads, if (progress) painter.hook() else null);
        defer results.deinit(gpa);
        var len = max_len;
        while (len >= cfg.min_len and len > 0) : (len -= 1) {
            const fams = results.forLength(len);
            total += fams.len;
            if (cfg.json) {
                for (fams) |one| {
                    try out.writeAll(if (first) "\n" else ",\n");
                    first = false;
                    if (is_fasta) try cli.writeJsonFamilyRecord(out, rec.name, subject, one) else try cli.writeJsonFamily(out, subject, one);
                }
            } else if (is_fasta) try cli.writeTsvRecord(out, rec.name, subject, fams) else try cli.writeTsv(out, subject, fams);
        }
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
