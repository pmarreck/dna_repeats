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
};

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
    std.mem.sort(Run, runs.items, {}, Run.lessByStart);

    // B: group overlapping runs (nested lengths of one array); extend each group's
    // longest run outward through degraded copies.
    var cands: std.ArrayList(Cand) = .empty;
    defer {
        for (cands.items) |c| gpa.free(c.copies);
        cands.deinit(gpa);
    }
    var i: usize = 0;
    while (i < runs.items.len) {
        var end = runs.items[i].end;
        var best = runs.items[i];
        var j = i + 1;
        while (j < runs.items.len and runs.items[j].start < end) : (j += 1) {
            const r = runs.items[j];
            end = @max(end, r.end);
            // Most copies first (a chance 2-copy flank extension must not beat the true unit), then longest.
            if (r.copies.len > best.copies.len or (r.copies.len == best.copies.len and r.len > best.len)) best = r;
        }
        const copies = try extend(gpa, subject, best, params);
        try cands.append(gpa, .{ .start = copies[0], .end = copies[copies.len - 1] + best.len, .len = best.len, .copies = copies });
        i = j;
    }
    std.mem.sort(Cand, cands.items, {}, Cand.lessByStart);

    // C: merge candidates that now overlap (fragments bridged by extension); judge
    // each merged array by its longest unit.
    var out: std.ArrayList(Array) = .empty;
    errdefer out.deinit(gpa);
    i = 0;
    while (i < cands.items.len) {
        var end = cands.items[i].end;
        var best = cands.items[i];
        var j = i + 1;
        while (j < cands.items.len and cands.items[j].start < end) : (j += 1) {
            const c = cands.items[j];
            end = @max(end, c.end);
            if (c.copies.len > best.copies.len or (c.copies.len == best.copies.len and c.len > best.len)) best = c;
        }
        if (best.copies.len >= params.min_copies and
            similarSpacerFraction(subject, best.copies, best.len, params.max_spacer_identity) <= params.max_similar_spacer_fraction and
            selfSimilarity(subject[best.copies[0]..][0..best.len]) <= params.max_unit_self_similarity and
            !(best.len >= params.max_unit and extendable(subject, best.copies, best.len)))
        {
            try out.append(gpa, .{ .start = best.start, .end = best.end, .copies = best.copies.len, .unit_len = best.len, .unit_pos = best.copies[0] });
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

    fn lessByStart(_: void, a: Run, b: Run) bool {
        return a.start < b.start;
    }
};

/// An extended array candidate owning its copy positions.
const Cand = struct {
    start: usize,
    end: usize,
    len: usize,
    copies: []usize,

    fn lessByStart(_: void, a: Cand, b: Cand) bool {
        return a.start < b.start;
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
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "spacers shorter than min_spacer are not an array" {
    var buf: [400]u8 = undefined;
    const subject = plant(&buf, 13, &.{ 50, 83, 116, 149 }); // 10-base spacers
    const arrays = try callOn(subject, .{});
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}

test "separate arrays are reported separately, in position order" {
    var buf: [900]u8 = undefined;
    const subject = plant(&buf, 15, &.{ 40, 95, 151, 600, 655, 709 });
    const arrays = try callOn(subject, .{});
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 50), arrays[0].start);
    try testing.expectEqual(@as(usize, 374 + dr.len), arrays[0].end);
    try testing.expectEqual(@as(usize, 7), arrays[0].copies);
}

test "two exact copies plus a degraded third make an array" {
    var buf: [400]u8 = undefined;
    const bad = degraded(2);
    const subject = plantWith(&buf, 32, &.{ 50, 104, 160 }, 160, &bad);
    const arrays = try callOn(subject, .{});
    defer testing.allocator.free(arrays);
    try testing.expectEqual(@as(usize, 1), arrays.len);
    try testing.expectEqual(@as(usize, 3), arrays[0].copies);
    try testing.expectEqual(@as(usize, 160 + dr.len), arrays[0].end);
}

test "a copy past max_copy_mismatches is not counted" {
    var buf: [400]u8 = undefined;
    const bad = degraded(9);
    const subject = plantWith(&buf, 33, &.{ 50, 104, 160 }, 160, &bad);
    const arrays = try callOn(subject, .{});
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
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
    defer testing.allocator.free(arrays);
    try testing.expectEqual(@as(usize, 0), arrays.len);
}
