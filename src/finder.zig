//! Fixed-length repeat-family finder using PCRE2 capture history (handoff section 8.1)
//! and the chain_packing family rule chosen by Peter on 2026-09-24.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("pcre2_c");
const ch = @import("pcre2_capture_history");
const fam = @import("families.zig");

const Api = ch.Api(8);

pub const Error = error{ Compile, OutOfMemory, MatchFailed };

/// One compiled fixed-length pattern plus reusable match data.
pub const Finder = struct {
    code: *c.pcre2_code_8,
    md: *c.pcre2_match_data_8,
    len: usize,
    unit_group: u32,
    hit_group: u32,

    /// Compile the lazy atomic bounded-gap chain pattern for one length and gap bound
    /// (gap bytes match DOTALL `.`, 1.10x faster in the JIT than an [ACGT] class),
    /// for an unanchored scan (`families`).
    pub fn init(len: usize, max_gap: usize) Error!Finder {
        return compile(len, max_gap, 0);
    }

    /// The same pattern anchored at the start offset, for probing chosen starts
    /// (`familiesAt`). Anchoring is a compile option because a match-time
    /// PCRE2_ANCHORED would make pcre2_match bypass the JIT.
    pub fn initAnchored(len: usize, max_gap: usize) Error!Finder {
        return compile(len, max_gap, c.PCRE2_ANCHORED);
    }

    fn compile(len: usize, max_gap: usize, options: u32) Error!Finder {
        var buf: [160]u8 = undefined;
        const pattern = std.fmt.bufPrint(&buf, "(*CAPTURE_HISTORY)(?s)(?=(?<unit>[ACGT]{{{d}}})(?:(?>.{{0,{d}}}?(?<hit>\\k<unit>)))++)", .{ len, max_gap }) catch return error.Compile;
        var err: c_int = 0;
        var off: usize = 0;
        const code = c.pcre2_compile_8(pattern.ptr, pattern.len, options, &err, &off, null) orelse return error.Compile;
        errdefer c.pcre2_code_free_8(code);
        // Best effort: without JIT support pcre2_match falls back to the interpreter.
        _ = c.pcre2_jit_compile_8(code, c.PCRE2_JIT_COMPLETE);
        const md = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return error.OutOfMemory;
        return .{
            .code = code,
            .md = md,
            .len = len,
            .unit_group = @intCast(c.pcre2_substring_number_from_name_8(code, "unit")),
            .hit_group = @intCast(c.pcre2_substring_number_from_name_8(code, "hit")),
        };
    }

    pub fn deinit(self: Finder) void {
        c.pcre2_match_data_free_8(self.md);
        c.pcre2_code_free_8(self.code);
    }

    /// chain_packing: take each start's regex chain in start order, skipping a start
    /// already inside an accepted member of the same unit. Such starts are skipped
    /// before matching, since the unit is just subject[s..][0..len].
    /// complexity: one unanchored scan, O(n) chain-start attempts; each chain step scans up to D+1 gap offsets
    /// with an O(L) backreference comparison at each.
    pub fn families(self: Finder, gpa: Allocator, subject: []const u8) Error![]fam.Family {
        var packer: Packer = .{};
        defer packer.deinit(gpa);
        if (self.len == 0 or self.len > subject.len) return packer.finish(gpa);
        // One unanchored scan: the JIT finds the next chain start itself, so there is
        // one pcre2_match call per chain rather than one per subject offset.
        const ovector = c.pcre2_get_ovector_pointer_8(self.md);
        var from: usize = 0;
        while (from + self.len <= subject.len) {
            const rc = c.pcre2_match_8(self.code, subject.ptr, subject.len, from, 0, self.md, null);
            if (rc == c.PCRE2_ERROR_NOMATCH) break;
            if (rc < 0) return error.MatchFailed;
            const start = ovector[0];
            from = start + 1;
            if (!packer.covered(subject, self.len, start)) try packer.accept(gpa, self, subject, start);
        }
        return packer.finish(gpa);
    }

    /// chain_packing restricted to `starts` (ascending), for an `initAnchored` finder.
    /// Exact whenever `starts` includes every offset whose chain matches, as
    /// `candidateStarts` guarantees; other offsets would only fail to match.
    /// complexity: one anchored match per candidate start.
    pub fn familiesAt(self: Finder, gpa: Allocator, subject: []const u8, starts: []const usize) Error![]fam.Family {
        var packer: Packer = .{};
        defer packer.deinit(gpa);
        if (self.len == 0) return packer.finish(gpa);
        for (starts) |start| {
            if (start + self.len > subject.len) break;
            if (packer.covered(subject, self.len, start)) continue;
            const rc = c.pcre2_match_8(self.code, subject.ptr, subject.len, start, 0, self.md, null);
            if (rc == c.PCRE2_ERROR_NOMATCH) continue;
            if (rc < 0) return error.MatchFailed;
            try packer.accept(gpa, self, subject, start);
        }
        return packer.finish(gpa);
    }
};

/// Accumulates chain_packing families: per unit, the end of its last accepted member,
/// so later starts inside that member are skipped.
const Packer = struct {
    out: std.ArrayList(fam.Family) = .empty,
    covered_until: std.StringHashMapUnmanaged(usize) = .empty,
    positions: std.ArrayList(usize) = .empty,

    fn covered(self: *Packer, subject: []const u8, len: usize, start: usize) bool {
        const until = self.covered_until.get(subject[start..][0..len]) orelse return false;
        return start < until;
    }

    /// Record the chain the finder just matched at `start` from its capture history.
    fn accept(self: *Packer, gpa: Allocator, f: Finder, subject: []const u8, start: usize) Error!void {
        self.positions.clearRetainingCapacity();
        for (Api.events(f.md)) |ev| {
            if (ev.group == f.unit_group or ev.group == f.hit_group) try self.positions.append(gpa, ev.start);
        }
        const last = self.positions.items[self.positions.items.len - 1];
        try self.covered_until.put(gpa, subject[start..][0..f.len], last + f.len);
        try self.out.append(gpa, .{ .len = f.len, .positions = try gpa.dupe(usize, self.positions.items) });
    }

    fn finish(self: *Packer, gpa: Allocator) Error![]fam.Family {
        return self.out.toOwnedSlice(gpa);
    }

    fn deinit(self: *Packer, gpa: Allocator) void {
        for (self.out.items) |f| gpa.free(f.positions);
        self.out.deinit(gpa);
        self.covered_until.deinit(gpa);
        self.positions.deinit(gpa);
    }
};

/// Families for every length in [min_len, max_len], indexed by len - min_len.
pub const LengthResults = struct {
    min_len: usize,
    per_length: [][]fam.Family,

    pub fn forLength(self: LengthResults, len: usize) []fam.Family {
        return self.per_length[len - self.min_len];
    }

    pub fn deinit(self: *LengthResults, gpa: Allocator) void {
        for (self.per_length) |fams| fam.freeFamilies(gpa, fams);
        gpa.free(self.per_length);
    }
};

/// Progress hook, invoked only on the calling thread with lengths completed so far.
pub const StepFn = struct {
    ctx: *anyopaque,
    step: *const fn (ctx: *anyopaque, done: usize, total: usize) void,
};

/// Runs every length's anchored chain_packing over `starts` on up to `threads` threads
/// (the caller included). Lengths are independent, so this is a bounded worker pool
/// claiming lengths from an atomic counter; results land in per-length slots, keeping
/// output order independent of scheduling. The allocator must be thread-safe.
pub fn familiesByLength(
    gpa: Allocator,
    subject: []const u8,
    starts: []const usize,
    min_len: usize,
    max_len: usize,
    max_gap: usize,
    threads: usize,
    progress: ?StepFn,
) (Error || std.Thread.SpawnError)!LengthResults {
    const lo = @max(min_len, 1);
    const total = if (max_len >= lo) max_len - lo + 1 else 0;
    const slots = try gpa.alloc([]fam.Family, total);
    for (slots) |*s| s.* = &.{};
    var results: LengthResults = .{ .min_len = lo, .per_length = slots };
    errdefer results.deinit(gpa);

    var pool: Pool = .{ .gpa = gpa, .subject = subject, .starts = starts, .lo = lo, .max_gap = max_gap, .slots = slots };
    const helpers = try gpa.alloc(std.Thread, @min(threads, total) -| 1);
    defer gpa.free(helpers);
    var spawned: usize = 0;
    defer for (helpers[0..spawned]) |t| t.join();
    for (helpers) |*t| {
        t.* = try std.Thread.spawn(.{}, Pool.work, .{ &pool, null });
        spawned += 1;
    }
    Pool.work(&pool, progress);
    for (helpers[0..spawned]) |t| t.join();
    spawned = 0;
    if (pool.failed.load(.acquire)) return error.MatchFailed;
    if (progress) |p| p.step(p.ctx, total, total);
    return results;
}

const Pool = struct {
    gpa: Allocator,
    subject: []const u8,
    starts: []const usize,
    lo: usize,
    max_gap: usize,
    slots: [][]fam.Family,
    next: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn work(self: *Pool, progress: ?StepFn) void {
        while (!self.failed.load(.acquire)) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.slots.len) return;
            self.slots[i] = self.one(self.lo + i) catch {
                self.failed.store(true, .release);
                return;
            };
            const done = self.done.fetchAdd(1, .acq_rel) + 1;
            if (progress) |p| p.step(p.ctx, done, self.slots.len);
        }
    }

    fn one(self: *Pool, len: usize) Error![]fam.Family {
        const f = try Finder.initAnchored(len, self.max_gap);
        defer f.deinit();
        return f.familiesAt(self.gpa, self.subject, self.starts);
    }
};

/// Offsets that can start a chain of any length in [min_len, max_len] under max_gap.
/// A length-L chain at s has a copy within max_gap of s+L, so the length-min_len
/// prefix at s has that copy within max_gap + (L - min_len) of its end: one scan
/// with the widened gap finds a superset of every length's chain starts.
/// complexity: one unanchored scan at min_len.
pub fn candidateStarts(gpa: Allocator, subject: []const u8, min_len: usize, max_len: usize, max_gap: usize) Error![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(gpa);
    const lo = @max(min_len, 1);
    if (max_len < lo or lo > subject.len) return starts.toOwnedSlice(gpa);
    try scanStarts(gpa, subject, lo, max_gap + (max_len - lo), 0, subject.len, &starts);
    return starts.toOwnedSlice(gpa);
}

/// Append every offset in [from, until) where a length-`len` unit has a copy within
/// `gap` bases after it, using one unanchored scan over `subject`.
/// The pattern only asks whether one copy exists (no capture history, no chain), so
/// each start costs at most gap+1 attempts even inside long tandem runs, where walking
/// the whole chain per start was quadratic. It matches exactly where the chain pattern
/// does, since that pattern's `++` requires at least one copy.
/// complexity: O((until - from) * gap) attempts, each an O(len) backreference compare.
fn scanStarts(gpa: Allocator, subject: []const u8, len: usize, gap: usize, from_start: usize, until: usize, out: *std.ArrayList(usize)) Error!void {
    var buf: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&buf, "(?s)(?=([ACGT]{{{d}}}).{{0,{d}}}?\\1)", .{ len, gap }) catch return error.Compile;
    var err: c_int = 0;
    var off: usize = 0;
    const code = c.pcre2_compile_8(pattern.ptr, pattern.len, 0, &err, &off, null) orelse return error.Compile;
    defer c.pcre2_code_free_8(code);
    _ = c.pcre2_jit_compile_8(code, c.PCRE2_JIT_COMPLETE);
    const md = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return error.OutOfMemory;
    defer c.pcre2_match_data_free_8(md);
    const ovector = c.pcre2_get_ovector_pointer_8(md);
    var from = from_start;
    while (from < until and from + len <= subject.len) {
        const rc = c.pcre2_match_8(code, subject.ptr, subject.len, from, 0, md, null);
        if (rc == c.PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) return error.MatchFailed;
        if (ovector[0] >= until) break;
        try out.append(gpa, ovector[0]);
        from = ovector[0] + 1;
    }
}

/// Below this many start offsets, thread startup costs more than it saves
/// (2900 bases: same wall time, 5x the system time with 17 threads).
pub const parallel_min_offsets = 16 * 1024;

pub const ScanOptions = struct {
    threads: usize,
    /// Fewest start offsets worth a thread; smaller inputs scan on the calling thread.
    min_chunk: usize = parallel_min_offsets,
};

/// `candidateStarts` with the start offsets split into contiguous chunks scanned on
/// separate threads. Each chunk sees the subject only up to its last start plus the
/// longest window a first copy can need (last start + 2*len + widened gap), which cannot change
/// whether one of its starts matches, so ending the scan there bounds each thread's
/// work to its own chunk. Chunks are concatenated in order.
pub fn candidateStartsParallel(gpa: Allocator, subject: []const u8, min_len: usize, max_len: usize, max_gap: usize, opts: ScanOptions) (Error || std.Thread.SpawnError)![]usize {
    const lo = @max(min_len, 1);
    if (max_len < lo or lo > subject.len) return gpa.alloc(usize, 0);
    const gap = max_gap + (max_len - lo);
    const offsets = subject.len - lo + 1;
    const chunks = @max(1, @min(opts.threads, offsets / @max(opts.min_chunk, 1)));
    if (chunks == 1) return candidateStarts(gpa, subject, min_len, max_len, max_gap);

    const parts = try gpa.alloc(ScanChunk, chunks);
    defer {
        for (parts) |*p| p.starts.deinit(gpa);
        gpa.free(parts);
    }
    const span = (offsets + chunks - 1) / chunks;
    for (parts, 0..) |*p, i| {
        const from = @min(i * span, offsets);
        const until = @min(from + span, offsets);
        p.* = .{ .gpa = gpa, .subject = subject[0..@min(subject.len, until - 1 + 2 * lo + gap)], .len = lo, .gap = gap, .from = from, .until = until };
    }
    const helpers = try gpa.alloc(std.Thread, chunks - 1);
    defer gpa.free(helpers);
    var spawned: usize = 0;
    defer for (helpers[0..spawned]) |t| t.join();
    for (helpers, parts[1..]) |*t, *p| {
        t.* = try std.Thread.spawn(.{}, ScanChunk.run, .{p});
        spawned += 1;
    }
    parts[0].run();
    for (helpers[0..spawned]) |t| t.join();
    spawned = 0;

    var total: usize = 0;
    for (parts) |p| {
        if (p.failed) return error.MatchFailed;
        total += p.starts.items.len;
    }
    const all = try gpa.alloc(usize, total);
    var at: usize = 0;
    for (parts) |p| {
        @memcpy(all[at..][0..p.starts.items.len], p.starts.items);
        at += p.starts.items.len;
    }
    return all;
}

const ScanChunk = struct {
    gpa: Allocator,
    subject: []const u8,
    len: usize,
    gap: usize,
    from: usize,
    until: usize,
    starts: std.ArrayList(usize) = .empty,
    failed: bool = false,

    fn run(self: *ScanChunk) void {
        scanStarts(self.gpa, self.subject, self.len, self.gap, self.from, self.until, &self.starts) catch {
            self.failed = true;
        };
    }
};

/// Families of exactly `len` under chain_packing, ordered by first position.
pub fn findFamilies(gpa: Allocator, subject: []const u8, len: usize, max_gap: usize) Error![]fam.Family {
    const finder = try Finder.init(len, max_gap);
    defer finder.deinit();
    return finder.families(gpa, subject);
}

const testing = std.testing;

fn expectMatchesOracle(subject: []const u8, len: usize, max_gap: usize) !void {
    const want = try fam.families(testing.allocator, subject, len, max_gap, .chain_packing);
    defer fam.freeFamilies(testing.allocator, want);
    const got = try findFamilies(testing.allocator, subject, len, max_gap);
    defer fam.freeFamilies(testing.allocator, got);
    if (!fam.sameFamilies(want, got)) {
        std.debug.print("{s} L={d} D={d}: oracle", .{ subject, len, max_gap });
        for (want) |f| std.debug.print(" {any}", .{f.positions});
        std.debug.print(" finder", .{});
        for (got) |f| std.debug.print(" {any}", .{f.positions});
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "the finder's pattern is JIT-compiled" {
    const f = try Finder.init(8, 300);
    defer f.deinit();
    var jit_size: usize = 0;
    try testing.expectEqual(@as(c_int, 0), c.pcre2_pattern_info_8(f.code, c.PCRE2_INFO_JITSIZE, &jit_size));
    try testing.expect(jit_size > 0);
}

/// Oracle check for the pruned path: candidates from one wide-gap scan, then anchored
/// chains at those starts only, for every length in [min_len, max_len].
fn expectPrunedMatchesOracle(subject: []const u8, min_len: usize, max_len: usize, max_gap: usize) !void {
    const starts = try candidateStarts(testing.allocator, subject, min_len, max_len, max_gap);
    defer testing.allocator.free(starts);
    var len = min_len;
    while (len <= max_len) : (len += 1) {
        const want = try fam.families(testing.allocator, subject, len, max_gap, .chain_packing);
        defer fam.freeFamilies(testing.allocator, want);
        const f = try Finder.initAnchored(len, max_gap);
        defer f.deinit();
        const got = try f.familiesAt(testing.allocator, subject, starts);
        defer fam.freeFamilies(testing.allocator, got);
        if (!fam.sameFamilies(want, got)) {
            std.debug.print("pruned {s} L={d} (range {d}..{d}) D={d}\n", .{ subject, len, min_len, max_len, max_gap });
            return error.TestUnexpectedResult;
        }
    }
}

test "pruned finder equals the chain_packing oracle on every small subject" {
    inline for (.{ .{ "AC", 9 }, .{ "ACGT", 6 }, .{ "ACN", 7 } }) |spec| {
        const alphabet = spec[0];
        var subject: [spec[1]]u8 = undefined;
        var n: usize = 1;
        while (n <= subject.len) : (n += 1) {
            var code: usize = 0;
            const combos = std.math.pow(usize, alphabet.len, n);
            while (code < combos) : (code += 1) {
                var x = code;
                for (subject[0..n]) |*b| {
                    b.* = alphabet[x % alphabet.len];
                    x /= alphabet.len;
                }
                var lo: usize = 1;
                while (lo <= @min(3, n)) : (lo += 1) {
                    var d: usize = 0;
                    while (d <= 2) : (d += 1) try expectPrunedMatchesOracle(subject[0..n], lo, @min(4, n), d);
                }
            }
        }
    }
}

/// Deterministic pseudo-random A/C/G/T with planted near copies (Park-Miller LCG).
fn lcgSubject(buf: []u8, seed: u64) []u8 {
    var s: u64 = seed;
    var i: usize = 0;
    while (i < buf.len) {
        s = s * 16807 % 2147483647;
        if (s % 29 == 0 and i > 40) {
            const len = @min(4 + s % 7, buf.len - i);
            const back = len + s % 30;
            @memmove(buf[i..][0..len], buf[i - back ..][0..len]);
            i += len;
        } else {
            buf[i] = "ACGT"[s % 4];
            i += 1;
        }
    }
    return buf;
}

const StepLog = struct {
    calls: usize = 0,
    last_done: usize = 0,
    total: usize = 0,
    fn step(ctx: *anyopaque, done: usize, total: usize) void {
        const self: *StepLog = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_done = done;
        self.total = total;
    }
};

test "parallel lengths equal the sequential finder for any thread count" {
    var buf: [700]u8 = undefined;
    const subject = lcgSubject(&buf, 7);
    const min_len = 3;
    const max_len = 9;
    const max_gap = 20;
    const starts = try candidateStarts(testing.allocator, subject, min_len, max_len, max_gap);
    defer testing.allocator.free(starts);
    for ([_]usize{ 1, 2, 4, 7, 32 }) |threads| {
        var log: StepLog = .{};
        var got = try familiesByLength(testing.allocator, subject, starts, min_len, max_len, max_gap, threads, .{ .ctx = &log, .step = StepLog.step });
        defer got.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, max_len - min_len + 1), got.per_length.len);
        var len: usize = min_len;
        while (len <= max_len) : (len += 1) {
            const want = try findFamilies(testing.allocator, subject, len, max_gap);
            defer fam.freeFamilies(testing.allocator, want);
            try testing.expect(fam.sameFamilies(want, got.forLength(len)));
        }
        try testing.expect(log.calls >= 1);
        try testing.expectEqual(log.total, log.last_done);
        try testing.expectEqual(@as(usize, max_len - min_len + 1), log.total);
    }
}

test "chunked parallel candidate scan equals the sequential scan" {
    var buf: [700]u8 = undefined;
    for ([_]u64{ 1, 7, 99 }) |seed| {
        const subject = lcgSubject(&buf, seed);
        for ([_][3]usize{ .{ 3, 9, 20 }, .{ 1, 4, 0 }, .{ 5, 5, 60 } }) |spec| {
            const want = try candidateStarts(testing.allocator, subject, spec[0], spec[1], spec[2]);
            defer testing.allocator.free(want);
            for ([_]usize{ 2, 3, 8 }) |threads| {
                for ([_]usize{ 1, 50, 1000 }) |min_chunk| {
                    const got = try candidateStartsParallel(testing.allocator, subject, spec[0], spec[1], spec[2], .{ .threads = threads, .min_chunk = min_chunk });
                    defer testing.allocator.free(got);
                    try testing.expectEqualSlices(usize, want, got);
                }
            }
        }
    }
}

test "chunked candidate scan is exact at every chunk boundary (exhaustive)" {
    var subject: [10]u8 = undefined;
    var n: usize = 2;
    while (n <= subject.len) : (n += 1) {
        var code: usize = 0;
        while (code < (@as(usize, 1) << @intCast(n))) : (code += 1) {
            for (subject[0..n], 0..) |*b, i| b.* = if (code >> @intCast(i) & 1 == 1) 'C' else 'A';
            for ([_][3]usize{ .{ 1, 2, 1 }, .{ 2, 2, 2 }, .{ 2, 3, 0 } }) |spec| {
                const want = try candidateStarts(testing.allocator, subject[0..n], spec[0], spec[1], spec[2]);
                defer testing.allocator.free(want);
                for ([_]usize{ 2, 3, 4 }) |threads| {
                    const got = try candidateStartsParallel(testing.allocator, subject[0..n], spec[0], spec[1], spec[2], .{ .threads = threads, .min_chunk = 1 });
                    defer testing.allocator.free(got);
                    try testing.expectEqualSlices(usize, want, got);
                }
            }
        }
    }
}

test "candidate starts exclude offsets that cannot repeat" {
    // No 2-mer here recurs, so no start can begin a family of length >= 2.
    const starts = try candidateStarts(testing.allocator, "ACGTTGCA", 2, 4, 3);
    defer testing.allocator.free(starts);
    try testing.expectEqual(@as(usize, 0), starts.len);
    // AC recurs 1 base after itself (within the widened gap of 1); only offset 0 qualifies.
    const some = try candidateStarts(testing.allocator, "ACGACTT", 2, 3, 0);
    defer testing.allocator.free(some);
    try testing.expectEqualSlices(usize, &.{0}, some);
}

test "hand examples match the oracle" {
    try expectMatchesOracle("AAAAAA", 2, 0);
    try expectMatchesOracle("AAACAA", 2, 1);
    try expectMatchesOracle("ACGTTACGTTTACGTCCCCCCCCCCCCACGT", 4, 10);
}

// Differential: exhaustive over {A,C}^1..9, L 1..4, D 0..2, plus {A,C,G,T}^1..6 and {A,C,N}^1..7 (N never in a unit).
test "finder equals the chain_packing oracle on every small subject" {
    inline for (.{ .{ "AC", 9 }, .{ "ACGT", 6 }, .{ "ACN", 7 } }) |spec| {
        const alphabet = spec[0];
        var subject: [spec[1]]u8 = undefined;
        var n: usize = 1;
        while (n <= subject.len) : (n += 1) {
            var code: usize = 0;
            const combos = std.math.pow(usize, alphabet.len, n);
            while (code < combos) : (code += 1) {
                var x = code;
                for (subject[0..n]) |*b| {
                    b.* = alphabet[x % alphabet.len];
                    x /= alphabet.len;
                }
                var len: usize = 1;
                while (len <= @min(4, n)) : (len += 1) {
                    var d: usize = 0;
                    while (d <= 2) : (d += 1) try expectMatchesOracle(subject[0..n], len, d);
                }
            }
        }
    }
}
