//! CRISPR-style array calling from repeat families (intents/beat_existing_tools.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fam = @import("families.zig");

pub const Params = struct {
    /// Fewest copies in an array (MinCED and PILER-CR also use 3).
    min_copies: usize = 3,
    /// Spacer (bases between consecutive copies) bounds.
    min_spacer: usize = 20,
    max_spacer: usize = 72,
    /// Most similar spacer pair allowed (positional identity); REP elements, tRNA
    /// clusters and coding repeats reuse near-identical "spacers".
    max_spacer_identity: f64 = 0.6,
    /// Largest share of spacer pairs allowed above max_spacer_identity: repeat elements
    /// reuse all their "spacers", while a real array may carry one duplicated spacer.
    max_similar_spacer_fraction: f64 = 0.2,
    /// Longest unit searched: a repeat still extendable at this length is too long for CRISPR.
    max_unit: usize = std.math.maxInt(usize),
    /// Mismatches allowed per extended copy, as a fraction of the unit (0.15: 4 of 29).
    max_copy_mismatch_fraction: f64 = 0.15,
    /// Highest self-similarity allowed for the unit (best match fraction against itself
    /// shifted by 1..len/2): CRISPR repeats are not internally periodic, while
    /// low-complexity coding repeats (e.g. PE_PGRS, period 9) are.
    max_unit_self_similarity: f64 = 0.7,
};

/// One called array: [start, end) in the record, 0-based.
pub const Array = struct {
    start: usize,
    end: usize,
    copies: usize,
    /// Longest unit among the merged families, and where one copy of it starts.
    unit_len: usize,
    unit_pos: usize,
    /// Start of every copy, ascending (0-based); owned, see freeArrays.
    positions: []usize,
};

pub fn freeArrays(gpa: Allocator, list: []const Array) void {
    for (list) |a| gpa.free(a.positions);
    gpa.free(list);
}

/// Call arrays from families of any lengths: split each family into maximal runs of
/// consecutive copies whose spacers are within bounds, keep runs with >= min_copies
/// copies and pairwise-distinct spacers (identical spacers mean a tandem repeat of
/// unit plus spacer), then merge overlapping runs so nested lengths of one array
/// collapse into a single region spanning their union.
/// complexity: O(F log F + sum of k^2 * spacer length) for F runs of k copies.
pub fn callArrays(gpa: Allocator, subject: []const u8, families: []const fam.Family, params: Params) Allocator.Error![]Array {
    // A: seeds, runs of >= 2 exact copies within spacer bounds.
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    for (families) |f| {
        var first: usize = 0;
        while (first < f.positions.len) {
            var last = first;
            while (last + 1 < f.positions.len) : (last += 1) {
                const gap = f.positions[last + 1] - f.positions[last] - f.len;
                if (gap < params.min_spacer or gap > params.max_spacer) break;
            }
            const copies = f.positions[first .. last + 1];
            if (copies.len >= 2) {
                try runs.append(gpa, .{ .start = copies[0], .end = copies[copies.len - 1] + f.len, .len = f.len, .copies = copies });
            }
            first = last + 1;
        }
    }

    // B: greedy peel, best seed first (most copies, then longest): a run overlapping an
    // accepted array is one of its nested lengths or a chance fragment and is skipped;
    // otherwise it is extended outward through degraded copies and accepted. Unlike
    // grouping by overlap, neighboring arrays welded by chance runs each keep their seed.
    std.mem.sort(Run, runs.items, {}, Run.moreCopiesFirst);
    var cands: std.ArrayList(Cand) = .empty;
    defer {
        for (cands.items) |c| gpa.free(c.copies);
        cands.deinit(gpa);
    }
    var covered: Coverage = .{};
    defer covered.deinit(gpa);
    for (runs.items) |r| {
        if (covered.overlaps(r.start, r.end)) continue;
        const copies = try extend(gpa, subject, r, params);
        errdefer gpa.free(copies);
        const cand: Cand = .{ .start = copies[0], .end = copies[copies.len - 1] + r.len, .len = r.len, .seed = r.copies[0], .copies = copies };
        try covered.add(gpa, cand.start, cand.end);
        try cands.append(gpa, cand);
    }
    std.mem.sort(Cand, cands.items, {}, Cand.lessByStart);

    // C: merge candidates that overlap after extension (fragments bridged through a
    // degraded copy) into their union; judge each merged array by its best candidate.
    var out: std.ArrayList(Array) = .empty;
    errdefer {
        for (out.items) |a| gpa.free(a.positions);
        out.deinit(gpa);
    }
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(gpa);
    var i: usize = 0;
    while (i < cands.items.len) {
        var end = cands.items[i].end;
        var best = cands.items[i];
        positions.clearRetainingCapacity();
        try positions.appendSlice(gpa, cands.items[i].copies);
        var last_copy_end = cands.items[i].end;
        var j = i + 1;
        while (j < cands.items.len and cands.items[j].start < end) : (j += 1) {
            const c = cands.items[j];
            end = @max(end, c.end);
            // Take only this candidate's copies past those already taken.
            for (c.copies) |p| if (p >= last_copy_end) {
                try positions.append(gpa, p);
                last_copy_end = p + c.len;
            };
            if (c.copies.len > best.copies.len or (c.copies.len == best.copies.len and c.len > best.len)) best = c;
        }
        const copies = positions.items.len;
        if (copies >= params.min_copies and
            similarSpacerFraction(subject, best.copies, best.len, params.max_spacer_identity) <= params.max_similar_spacer_fraction and
            selfSimilarity(subject[best.seed..][0..best.len]) <= params.max_unit_self_similarity and
            !(best.len >= params.max_unit and extendable(subject, best.copies, best.len)))
        {
            const owned = try gpa.dupe(usize, positions.items);
            errdefer gpa.free(owned);
            try out.append(gpa, .{ .start = cands.items[i].start, .end = end, .copies = copies, .unit_len = best.len, .unit_pos = best.seed, .positions = owned });
        }
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

/// A run of consecutive exact copies of one family, borrowing its positions.
const Run = struct {
    start: usize,
    end: usize,
    len: usize,
    copies: []const usize,

    fn moreCopiesFirst(_: void, a: Run, b: Run) bool {
        if (a.copies.len != b.copies.len) return a.copies.len > b.copies.len;
        if (a.len != b.len) return a.len > b.len;
        return a.start < b.start;
    }
};

/// An extended array candidate owning its copy positions; `seed` is an exact copy of the unit.
const Cand = struct {
    start: usize,
    end: usize,
    len: usize,
    seed: usize,
    copies: []usize,

    fn lessByStart(_: void, a: Cand, b: Cand) bool {
        return a.start < b.start;
    }
};

/// Disjoint, sorted intervals of accepted arrays; overlap queries by binary search.
const Coverage = struct {
    spans: std.ArrayList([2]usize) = .empty,

    /// Index of the first span ending after `start`.
    fn firstEndingAfter(self: Coverage, start: usize) usize {
        var lo: usize = 0;
        var hi = self.spans.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.spans.items[mid][1] <= start) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn overlaps(self: Coverage, start: usize, end: usize) bool {
        const k = self.firstEndingAfter(start);
        return k < self.spans.items.len and self.spans.items[k][0] < end;
    }

    /// Insert [start, end), merging any spans it overlaps.
    fn add(self: *Coverage, gpa: Allocator, start: usize, end: usize) Allocator.Error!void {
        const k = self.firstEndingAfter(start);
        var m = k;
        var lo = start;
        var hi = end;
        while (m < self.spans.items.len and self.spans.items[m][0] < end) : (m += 1) {
            lo = @min(lo, self.spans.items[m][0]);
            hi = @max(hi, self.spans.items[m][1]);
        }
        try self.spans.replaceRange(gpa, k, m - k, &.{.{ lo, hi }});
    }

    fn deinit(self: *Coverage, gpa: Allocator) void {
        self.spans.deinit(gpa);
    }
};

/// Seed-and-extend: from the run's first and last copies, repeatedly take the nearest
/// window within the spacer bounds whose Hamming distance to the run's unit is within
/// the mismatch budget. Returns all copy positions, ascending (caller owns).
/// complexity: O(added copies * (max_spacer - min_spacer) * unit length).
fn extend(gpa: Allocator, subject: []const u8, run: Run, params: Params) Allocator.Error![]usize {
    const unit = subject[run.copies[0]..][0..run.len];
    const budget: usize = @intFromFloat(@floor(params.max_copy_mismatch_fraction * @as(f64, @floatFromInt(run.len))));
    var left: std.ArrayList(usize) = .empty;
    defer left.deinit(gpa);
    var cur = run.copies[0];
    while (cur >= run.len + params.min_spacer) {
        const hi = cur - run.len - params.min_spacer; // nearest allowed start going left
        const lo = cur -| (run.len + params.max_spacer);
        var q = hi + 1;
        const found = while (q > lo) {
            q -= 1;
            if (hamming(subject[q..][0..run.len], unit) <= budget) break q;
        } else null;
        cur = found orelse break;
        try left.append(gpa, cur);
    }
    var all: std.ArrayList(usize) = .empty;
    errdefer all.deinit(gpa);
    var k = left.items.len;
    while (k > 0) : (k -= 1) try all.append(gpa, left.items[k - 1]);
    try all.appendSlice(gpa, run.copies);
    cur = run.copies[run.copies.len - 1];
    while (true) {
        const lo = cur + run.len + params.min_spacer;
        const hi = @min(cur + run.len + params.max_spacer, subject.len -| run.len);
        var q = lo;
        const found = while (q <= hi) : (q += 1) {
            if (hamming(subject[q..][0..run.len], unit) <= budget) break q;
        } else null;
        cur = found orelse break;
        try all.append(gpa, cur);
    }
    return all.toOwnedSlice(gpa);
}

fn hamming(a: []const u8, b: []const u8) usize {
    var d: usize = 0;
    for (a, b) |x, y| d += @intFromBool(x != y);
    return d;
}

/// Share of spacer pairs whose positional identity (matching bases over the longer
/// length) exceeds `threshold`. complexity: O(k^2 * spacer length) for k copies.
fn similarSpacerFraction(subject: []const u8, copies: []const usize, len: usize, threshold: f64) f64 {
    var pairs: usize = 0;
    var similar: usize = 0;
    for (0..copies.len - 1) |i| {
        const a = subject[copies[i] + len .. copies[i + 1]];
        for (i + 1..copies.len - 1) |j| {
            const b = subject[copies[j] + len .. copies[j + 1]];
            const longer = @max(a.len, b.len);
            pairs += 1;
            if (longer == 0) {
                similar += 1;
                continue;
            }
            var same: usize = 0;
            for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| same += @intFromBool(x == y);
            if (@as(f64, @floatFromInt(same)) / @as(f64, @floatFromInt(longer)) > threshold) similar += 1;
        }
    }
    return if (pairs == 0) 0 else @as(f64, @floatFromInt(similar)) / @as(f64, @floatFromInt(pairs));
}

/// Best fraction of positions where the unit equals itself shifted by p, over p in 1..len/2.
fn selfSimilarity(unit: []const u8) f64 {
    var best: f64 = 0;
    var p: usize = 1;
    while (p <= unit.len / 2) : (p += 1) {
        var same: usize = 0;
        for (unit[0 .. unit.len - p], unit[p..]) |x, y| same += @intFromBool(x == y);
        best = @max(best, @as(f64, @floatFromInt(same)) / @as(f64, @floatFromInt(unit.len - p)));
    }
    return best;
}

/// True when every copy has the same base just before it, or just after it: the
/// repeat continues past this unit.
fn extendable(subject: []const u8, copies: []const usize, len: usize) bool {
    var left = copies[0] > 0;
    var right = copies[0] + len < subject.len;
    for (copies) |p| {
        left = left and p > 0 and subject[p - 1] == subject[copies[0] - 1];
        right = right and p + len < subject.len and subject[p + len] == subject[copies[0] + len];
    }
    return left or right;
}

const testing = std.testing;

/// Deterministic pseudo-random bases (Park-Miller LCG) so spacers and flanks are distinct.
fn fillRandom(buf: []u8, seed: u64) void {
    var s: u64 = seed;
    for (buf) |*b| {
        s = s * 16807 % 2147483647;
        b.* = "ACGT"[s % 4];
    }
}

const dr = "GTTTCAGTAGAACGTAATCGTGT"; // 23 bases

/// Background of random bases with `dr` written at each position in `at`.
fn plant(buf: []u8, seed: u64, at: []const usize) []u8 {
    fillRandom(buf, seed);
    for (at) |p| @memcpy(buf[p..][0..dr.len], dr);
    return buf;
}

fn callOn(subject: []const u8, params: Params) ![]Array {
    var all: std.ArrayList(fam.Family) = .empty;
    defer {
        for (all.items) |f| testing.allocator.free(f.positions);
        all.deinit(testing.allocator);
    }
    var len: usize = 20;
    while (len <= 30) : (len += 1) {
        const fams = try fam.families(testing.allocator, subject, len, params.max_spacer, .chain_packing);
        defer testing.allocator.free(fams);
        try all.appendSlice(testing.allocator, fams);
    }
    var p = params;
    p.max_unit = 30;
    return callArrays(testing.allocator, subject, all.items, p);
}

test "one array: nested lengths collapse into one region" {
    var buf: [400]u8 = undefined;
    const subject = plant(&buf, 11, &.{ 50, 103, 158, 210 });
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqualSlices(usize, &.{ 50, 103, 158, 210 }, arrays[0].positions);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 50), arrays[0].start);
    try testing.expectEqual(@as(usize, 210 + dr.len), arrays[0].end);
    try testing.expectEqual(@as(usize, 4), arrays[0].copies);
    try testing.expect(arrays[0].unit_len >= dr.len);
}

test "fewer than min_copies is not an array" {
    var buf: [400]u8 = undefined;
    const subject = plant(&buf, 12, &.{ 50, 103 });
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "spacers shorter than min_spacer are not an array" {
    var buf: [400]u8 = undefined;
    const subject = plant(&buf, 13, &.{ 50, 83, 116, 149 }); // 10-base spacers
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "identical spacers (a tandem repeat of unit plus spacer) are not an array" {
    var buf: [400]u8 = undefined;
    fillRandom(&buf, 14);
    const period = dr.len + 30;
    for (1..4) |k| @memcpy(buf[50 + k * period ..][0..period], buf[50..][0..period]);
    @memcpy(buf[50..][0..dr.len], dr);
    for (1..4) |k| @memcpy(buf[50 + k * period ..][0..period], buf[50..][0..period]);
    const arrays = try callOn(&buf, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "separate arrays are reported separately, in position order" {
    var buf: [900]u8 = undefined;
    const subject = plant(&buf, 15, &.{ 40, 95, 151, 600, 655, 709 });
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 2), arrays.len);
    try testing.expectEqual(@as(usize, 40), arrays[0].start);
    try testing.expectEqual(@as(usize, 600), arrays[1].start);
}

/// Copy `n` bases starting at `from` in `src` into `buf` at `at`, returning at + n.
fn put(buf: []u8, at: usize, bases: []const u8) usize {
    @memcpy(buf[at..][0..bases.len], bases);
    return at + bases.len;
}

test "near-identical spacers (over max_spacer_identity) are not an array" {
    var buf: [400]u8 = undefined;
    fillRandom(&buf, 21);
    var spacer: [30]u8 = undefined;
    fillRandom(&spacer, 22);
    var at: usize = 50;
    for (0..4) |k| {
        at = put(&buf, at, dr);
        if (k == 3) break;
        var s = spacer;
        s[k * 7] = if (s[k * 7] == 'A') 'C' else 'A'; // distinct spacers, one base apart
        at = put(&buf, at, &s);
    }
    const arrays = try callOn(&buf, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "a repeat longer than max_unit (extendable at the cap) is not an array" {
    var buf: [500]u8 = undefined;
    fillRandom(&buf, 23);
    var long_unit: [40]u8 = undefined; // callOn searches lengths 20..30
    fillRandom(&long_unit, 24);
    var at: usize = 50;
    for (0..3) |k| {
        at = put(&buf, at, &long_unit);
        var s: [30]u8 = undefined;
        fillRandom(&s, 30 + k);
        at = put(&buf, at, &s);
    }
    const arrays = try callOn(&buf, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

/// `dr` with `n` substitutions spread evenly across it.
fn degraded(n: usize) [dr.len]u8 {
    var d: [dr.len]u8 = dr.*;
    for (0..n) |k| {
        const i = (k * 7 + 3) % dr.len;
        d[i] = if (d[i] == 'A') 'C' else 'A';
    }
    return d;
}

/// Random background with copies of `dr` (or `alt` at `alt_at`) at `at`.
fn plantWith(buf: []u8, seed: u64, at: []const usize, alt_at: usize, alt: []const u8) []u8 {
    fillRandom(buf, seed);
    for (at) |p| @memcpy(buf[p..][0..dr.len], if (p == alt_at) alt else dr);
    return buf;
}

test "a degraded middle copy is bridged: one array spanning both exact runs" {
    var buf: [600]u8 = undefined;
    const bad = degraded(3);
    const at = [_]usize{ 50, 103, 157, 212, 266, 320, 374 };
    const subject = plantWith(&buf, 31, &at, 212, &bad);
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 50), arrays[0].start);
    try testing.expectEqual(@as(usize, 374 + dr.len), arrays[0].end);
    try testing.expectEqual(@as(usize, 7), arrays[0].copies);
    try testing.expectEqualSlices(usize, &.{ 50, 103, 157, 212, 266, 320, 374 }, arrays[0].positions);
}

test "two exact copies plus a degraded third make an array" {
    var buf: [400]u8 = undefined;
    const bad = degraded(2);
    const subject = plantWith(&buf, 32, &.{ 50, 104, 160 }, 160, &bad);
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 3), arrays[0].copies);
    try testing.expectEqual(@as(usize, 160 + dr.len), arrays[0].end);
}

test "a copy past max_copy_mismatches is not counted" {
    var buf: [400]u8 = undefined;
    const bad = degraded(9);
    const subject = plantWith(&buf, 33, &.{ 50, 104, 160 }, 160, &bad);
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "one duplicated spacer does not veto a long array" {
    var buf: [700]u8 = undefined;
    fillRandom(&buf, 41);
    var at: usize = 30;
    var spacers: [7][30]u8 = undefined;
    for (&spacers, 0..) |*s, k| fillRandom(s, 50 + k);
    spacers[5] = spacers[1]; // arrays can carry a duplicated spacer
    for (0..8) |k| {
        at = put(&buf, at, dr);
        if (k < 7) at = put(&buf, at, &spacers[k]);
    }
    const arrays = try callOn(&buf, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 8), arrays[0].copies);
}

test "an internally periodic (low-complexity) unit is not an array" {
    var buf: [400]u8 = undefined;
    fillRandom(&buf, 61);
    const periodic = "GCCGCCGGTGCCGCCGGTGCCGCC"; // period 9, like M. tuberculosis PE_PGRS repeats
    var at: usize = 50;
    for (0..4) |k| {
        at = put(&buf, at, periodic);
        var s: [30]u8 = undefined;
        fillRandom(&s, 70 + k);
        if (k < 3) at = put(&buf, at, &s);
    }
    const arrays = try callOn(&buf, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "neighboring arrays stay separate when a chance 2-copy run spans the gap between them" {
    var buf: [900]u8 = undefined;
    fillRandom(&buf, 81);
    const period = dr.len + 30;
    const a_start: usize = 40;
    const b_start = a_start + 4 * period + dr.len + 75; // 75 bases after A's last copy: past max_spacer
    for (0..5) |k| {
        @memcpy(buf[a_start + k * period ..][0..dr.len], dr);
        @memcpy(buf[b_start + k * period ..][0..dr.len], dr);
    }
    // A chance 27-mer (the repeat's last 10 bases plus 17 shared bases) starting inside
    // A's last copy and inside B's first copy: 2 copies 71 bases apart, so it overlaps both arrays.
    var tail: [17]u8 = undefined;
    fillRandom(&tail, 82);
    const a_last = a_start + 4 * period;
    @memcpy(buf[a_last + dr.len ..][0..tail.len], &tail);
    @memcpy(buf[b_start + dr.len ..][0..tail.len], &tail);
    const arrays = try callOn(&buf, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 2), arrays.len);
    try testing.expectEqual(a_start, arrays[0].start);
    try testing.expectEqual(@as(usize, 5), arrays[0].copies);
    try testing.expectEqual(b_start, arrays[1].start);
    try testing.expectEqual(@as(usize, 5), arrays[1].copies);
}

test "the reported unit is an exact copy, not a degraded one found by extension" {
    var buf: [400]u8 = undefined;
    const bad = degraded(3);
    const subject = plantWith(&buf, 91, &.{ 50, 104, 160, 215 }, 50, &bad);
    const arrays = try callOn(subject, .{});
    defer freeArrays(testing.allocator, arrays);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 50), arrays[0].start);
    try testing.expectEqual(@as(usize, 4), arrays[0].copies);
    try testing.expectEqualStrings(dr, subject[arrays[0].unit_pos..][0..dr.len]);
}

test "coverage: half-open overlap at every boundary, and merging spans" {
    var c: Coverage = .{};
    defer c.deinit(testing.allocator);
    try c.add(testing.allocator, 10, 20);
    try c.add(testing.allocator, 40, 50);
    // Classify every query [s, s+5) for s in 0..60 against spans [10,20) and [40,50).
    for (0..60) |s| {
        const want = (s + 5 > 10 and s < 20) or (s + 5 > 40 and s < 50);
        try testing.expectEqual(want, c.overlaps(s, s + 5));
    }
    try c.add(testing.allocator, 18, 42); // bridges both spans into one
    try testing.expectEqual(@as(usize, 1), c.spans.items.len);
    try testing.expectEqual([2]usize{ 10, 50 }, c.spans.items[0]);
    try c.add(testing.allocator, 50, 55); // touching, not overlapping: stays separate
    try testing.expectEqual(@as(usize, 2), c.spans.items.len);
}
