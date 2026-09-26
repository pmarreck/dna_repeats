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

    /// Compile the lazy atomic bounded-gap chain pattern for one length and gap bound,
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
        const pattern = std.fmt.bufPrint(&buf, "(*CAPTURE_HISTORY)(?=(?<unit>[ACGT]{{{d}}})(?:(?>[ACGT]{{0,{d}}}?(?<hit>\\k<unit>)))++)", .{ len, max_gap }) catch return error.Compile;
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
    const f = try Finder.init(lo, max_gap + (max_len - lo));
    defer f.deinit();
    const ovector = c.pcre2_get_ovector_pointer_8(f.md);
    var from: usize = 0;
    while (from + lo <= subject.len) {
        const rc = c.pcre2_match_8(f.code, subject.ptr, subject.len, from, 0, f.md, null);
        if (rc == c.PCRE2_ERROR_NOMATCH) break;
        if (rc < 0) return error.MatchFailed;
        try starts.append(gpa, ovector[0]);
        from = ovector[0] + 1;
    }
    return starts.toOwnedSlice(gpa);
}

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
    inline for (.{ .{ "AC", 9 }, .{ "ACGT", 6 } }) |spec| {
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

// Differential: exhaustive over {A,C}^1..9, L 1..4, D 0..2, plus {A,C,G,T}^1..6.
test "finder equals the chain_packing oracle on every small subject" {
    inline for (.{ .{ "AC", 9 }, .{ "ACGT", 6 } }) |spec| {
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
