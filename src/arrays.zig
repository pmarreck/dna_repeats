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
    /// Longest unit searched: a repeat still extendable at this length is too long for CRISPR.
    max_unit: usize = std.math.maxInt(usize),
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
            if (copies.len >= params.min_copies and spacersDistinct(subject, copies, f.len)) {
                try runs.append(gpa, .{ .start = copies[0], .end = copies[copies.len - 1] + f.len, .len = f.len, .copies = copies });
            }
            first = last + 1;
        }
    }
    std.mem.sort(Run, runs.items, {}, Run.lessByStart);
    var out: std.ArrayList(Array) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < runs.items.len) {
        // One cluster: runs overlapping the growing region, i.e. nested lengths of one array.
        var end = runs.items[i].end;
        var best = runs.items[i];
        var copies = best.copies.len;
        var j = i + 1;
        while (j < runs.items.len and runs.items[j].start < end) : (j += 1) {
            const r = runs.items[j];
            end = @max(end, r.end);
            copies = @max(copies, r.copies.len);
            if (r.len > best.len or (r.len == best.len and r.copies.len > best.copies.len)) best = r;
        }
        // Judge the cluster by its longest unit: shorter nested units carry repeat bases into their spacers.
        if (maxSpacerIdentity(subject, best.copies, best.len) <= params.max_spacer_identity and
            !(best.len >= params.max_unit and extendable(subject, best.copies, best.len)))
        {
            try out.append(gpa, .{ .start = runs.items[i].start, .end = end, .copies = copies, .unit_len = best.len, .unit_pos = best.copies[0] });
        }
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

/// A run of consecutive copies of one family, borrowing its positions.
const Run = struct {
    start: usize,
    end: usize,
    len: usize,
    copies: []const usize,

    fn lessByStart(_: void, a: Run, b: Run) bool {
        return a.start < b.start;
    }
};

/// Highest positional identity between any two spacers (matching bases over the longer length).
fn maxSpacerIdentity(subject: []const u8, copies: []const usize, len: usize) f64 {
    var best: f64 = 0;
    for (0..copies.len - 1) |i| {
        const a = subject[copies[i] + len .. copies[i + 1]];
        for (i + 1..copies.len - 1) |j| {
            const b = subject[copies[j] + len .. copies[j + 1]];
            const longer = @max(a.len, b.len);
            if (longer == 0) continue;
            var same: usize = 0;
            for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| same += @intFromBool(x == y);
            best = @max(best, @as(f64, @floatFromInt(same)) / @as(f64, @floatFromInt(longer)));
        }
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

fn spacersDistinct(subject: []const u8, copies: []const usize, len: usize) bool {
    for (0..copies.len - 1) |i| {
        const a = subject[copies[i] + len .. copies[i + 1]];
        for (i + 1..copies.len - 1) |j| {
            if (std.mem.eql(u8, a, subject[copies[j] + len .. copies[j + 1]])) return false;
        }
    }
    return true;
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
