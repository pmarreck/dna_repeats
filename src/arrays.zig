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
    var runs: std.ArrayList(Array) = .empty;
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
                try runs.append(gpa, .{ .start = copies[0], .end = copies[copies.len - 1] + f.len, .copies = copies.len, .unit_len = f.len, .unit_pos = copies[0] });
            }
            first = last + 1;
        }
    }
    std.mem.sort(Array, runs.items, {}, lessByStart);
    var out: std.ArrayList(Array) = .empty;
    errdefer out.deinit(gpa);
    for (runs.items) |r| {
        if (out.items.len > 0 and r.start < out.items[out.items.len - 1].end) {
            const cur = &out.items[out.items.len - 1];
            cur.end = @max(cur.end, r.end);
            cur.copies = @max(cur.copies, r.copies);
            if (r.unit_len > cur.unit_len) {
                cur.unit_len = r.unit_len;
                cur.unit_pos = r.unit_pos;
            }
        } else try out.append(gpa, r);
    }
    return out.toOwnedSlice(gpa);
}

fn lessByStart(_: void, a: Array, b: Array) bool {
    return a.start < b.start;
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
    return callArrays(testing.allocator, subject, all.items, params);
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
