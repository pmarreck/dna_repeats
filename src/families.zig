//! Brute-force reference rules for gap-constrained repeat families over small subjects.
//! Deliberately simple (quadratic scans, no PCRE2) so it can serve as an independent oracle.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Candidate definitions of a "family"; they disagree once occurrences can overlap.
pub const Rule = enum {
    /// Handoff section 26: every exact occurrence, overlaps included, split where gap > D.
    all_occurrences,
    /// Handoff section 10: union of positions reported by the fixed-L regex from every start, split where gap > D.
    regex_union,
    /// Each start's greedy non-overlapping chain, dropping chains that are suffixes of another chain.
    maximal_chains,
    /// Leftmost greedy non-overlapping packing of all occurrences, split where gap > D.
    greedy_packing,
    /// Regex chains accepted in start order, skipping starts inside an already accepted member.
    chain_packing,
};

/// One family: occurrence starts (ascending) of the unit subject[positions[0]..][0..len].
pub const Family = struct {
    len: usize,
    positions: []usize,
};

pub fn freeFamilies(gpa: Allocator, fams: []Family) void {
    for (fams) |f| gpa.free(f.positions);
    gpa.free(fams);
}

/// All families of exactly length `len` under `rule`, ordered by first position.
pub fn families(gpa: Allocator, subject: []const u8, len: usize, max_gap: usize, rule: Rule) ![]Family {
    var out: std.ArrayList(Family) = .empty;
    errdefer {
        for (out.items) |f| gpa.free(f.positions);
        out.deinit(gpa);
    }
    if (len == 0 or len > subject.len) return out.toOwnedSlice(gpa);

    var p: usize = 0;
    while (p + len <= subject.len) : (p += 1) {
        if (seenEarlier(subject, len, p)) continue;
        const occ = try occurrences(gpa, subject, len, p);
        defer gpa.free(occ);
        switch (rule) {
            .all_occurrences => try appendSplit(gpa, &out, occ, len, max_gap),
            .greedy_packing => {
                const packed_positions = try pack(gpa, occ, len);
                defer gpa.free(packed_positions);
                try appendSplit(gpa, &out, packed_positions, len, max_gap);
            },
            .regex_union => {
                var members: std.ArrayList(usize) = .empty;
                defer members.deinit(gpa);
                for (occ) |start| {
                    const c = try chain(gpa, occ, start, len, max_gap);
                    defer gpa.free(c);
                    if (c.len >= 2) try members.appendSlice(gpa, c);
                }
                std.mem.sort(usize, members.items, {}, std.sort.asc(usize));
                const unique = dedupSorted(members.items);
                try appendSplit(gpa, &out, unique, len, max_gap);
            },
            .chain_packing => {
                var covered_until: usize = 0;
                for (occ) |start| {
                    if (start < covered_until) continue;
                    const c = try chain(gpa, occ, start, len, max_gap);
                    if (c.len < 2) {
                        gpa.free(c);
                        continue;
                    }
                    covered_until = c[c.len - 1] + len;
                    try out.append(gpa, .{ .len = len, .positions = c });
                }
            },
            .maximal_chains => {
                for (occ) |start| {
                    if (isChainSuccessor(occ, start, len, max_gap)) continue;
                    const c = try chain(gpa, occ, start, len, max_gap);
                    if (c.len < 2) {
                        gpa.free(c);
                        continue;
                    }
                    try out.append(gpa, .{ .len = len, .positions = c });
                }
            },
        }
    }
    std.mem.sort(Family, out.items, {}, lessByFirst);
    return out.toOwnedSlice(gpa);
}

fn lessByFirst(_: void, a: Family, b: Family) bool {
    return a.positions[0] < b.positions[0];
}

fn seenEarlier(subject: []const u8, len: usize, p: usize) bool {
    var q: usize = 0;
    while (q < p) : (q += 1) {
        if (std.mem.eql(u8, subject[q..][0..len], subject[p..][0..len])) return true;
    }
    return false;
}

/// Every start whose len bytes equal those at `first`, overlaps included, ascending.
fn occurrences(gpa: Allocator, subject: []const u8, len: usize, first: usize) ![]usize {
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(gpa);
    var q = first;
    while (q + len <= subject.len) : (q += 1) {
        if (std.mem.eql(u8, subject[q..][0..len], subject[first..][0..len])) try list.append(gpa, q);
    }
    return list.toOwnedSlice(gpa);
}

/// Nearest non-overlapping occurrence within the gap bound, as the lazy bounded-gap regex finds it.
fn nextInChain(occ: []const usize, cur: usize, len: usize, max_gap: usize) ?usize {
    for (occ) |q| {
        if (q >= cur + len and q <= cur + len + max_gap) return q;
    }
    return null;
}

/// Positions one fixed-length regex match reports from `start`: the unit plus every hit.
fn chain(gpa: Allocator, occ: []const usize, start: usize, len: usize, max_gap: usize) ![]usize {
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, start);
    var cur = start;
    while (nextInChain(occ, cur, len, max_gap)) |q| {
        try list.append(gpa, q);
        cur = q;
    }
    return list.toOwnedSlice(gpa);
}

/// The chain the fixed-L regex reports when anchored at `start` (unit then hits), or just [start].
pub fn chainAt(gpa: Allocator, subject: []const u8, len: usize, max_gap: usize, start: usize) ![]usize {
    const occ = try occurrences(gpa, subject, len, firstOccurrence(subject, len, start));
    defer gpa.free(occ);
    return chain(gpa, occ, start, len, max_gap);
}

fn firstOccurrence(subject: []const u8, len: usize, p: usize) usize {
    var q: usize = 0;
    while (q < p) : (q += 1) {
        if (std.mem.eql(u8, subject[q..][0..len], subject[p..][0..len])) return q;
    }
    return p;
}

fn isChainSuccessor(occ: []const usize, target: usize, len: usize, max_gap: usize) bool {
    for (occ) |q| {
        if (nextInChain(occ, q, len, max_gap) == target) return true;
    }
    return false;
}

/// Leftmost greedy non-overlapping selection, ignoring the gap bound.
fn pack(gpa: Allocator, occ: []const usize, len: usize) ![]usize {
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(gpa);
    for (occ) |q| {
        if (list.items.len == 0 or q >= list.items[list.items.len - 1] + len) try list.append(gpa, q);
    }
    return list.toOwnedSlice(gpa);
}

fn dedupSorted(items: []usize) []usize {
    if (items.len == 0) return items;
    var w: usize = 1;
    for (items[1..]) |x| {
        if (x != items[w - 1]) {
            items[w] = x;
            w += 1;
        }
    }
    return items[0..w];
}

/// Split ascending starts where next - (cur + len) > max_gap; keep components of two or more.
/// Overlaps give a negative gap, which never splits.
fn appendSplit(gpa: Allocator, out: *std.ArrayList(Family), positions: []const usize, len: usize, max_gap: usize) !void {
    var i: usize = 0;
    while (i < positions.len) {
        var j = i + 1;
        while (j < positions.len and positions[j] <= positions[j - 1] + len + max_gap) : (j += 1) {}
        if (j - i >= 2) {
            try out.append(gpa, .{ .len = len, .positions = try gpa.dupe(usize, positions[i..j]) });
        }
        i = j;
    }
}

pub fn sameFamilies(a: []const Family, b: []const Family) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(usize, x.positions, y.positions)) return false;
    }
    return true;
}

/// A family whose consecutive members overlap violates the handoff's 0 <= gap rule.
pub fn hasOverlap(fams: []const Family) bool {
    for (fams) |f| {
        for (f.positions[1..], f.positions[0 .. f.positions.len - 1]) |next, cur| {
            if (next < cur + f.len) return true;
        }
    }
    return false;
}

const testing = std.testing;

/// Compare only the families of `unit`; other units' families are ignored.
fn expectFamilies(subject: []const u8, unit: []const u8, max_gap: usize, rule: Rule, expected: []const []const usize) !void {
    const fams = try families(testing.allocator, subject, unit.len, max_gap, rule);
    defer freeFamilies(testing.allocator, fams);
    var mine: [16][]const usize = undefined;
    var n: usize = 0;
    for (fams) |f| {
        if (std.mem.eql(u8, subject[f.positions[0]..][0..unit.len], unit)) {
            mine[n] = f.positions;
            n += 1;
        }
    }
    errdefer std.debug.print("unit {s} D={d} {s}: got {any}\n", .{ unit, max_gap, @tagName(rule), mine[0..n] });
    try testing.expectEqual(expected.len, n);
    for (expected, mine[0..n]) |want, got| try testing.expectEqualSlices(usize, want, got);
}

// Hand-derived: AAAAAA, L=2, D=0 has occurrences 0..4, each overlapping the next.
test "AAAAAA L=2 D=0: all occurrences join through negative gaps" {
    try expectFamilies("AAAAAA", "AA", 0, .all_occurrences, &.{&.{ 0, 1, 2, 3, 4 }});
}
test "AAAAAA L=2 D=0: regex union mixes two interleaved chains" {
    try expectFamilies("AAAAAA", "AA", 0, .regex_union, &.{&.{ 0, 1, 2, 3, 4 }});
}
test "AAAAAA L=2 D=0: maximal chains stay separate" {
    try expectFamilies("AAAAAA", "AA", 0, .maximal_chains, &.{ &.{ 0, 2, 4 }, &.{ 1, 3 } });
}
test "AAAAAA L=2 D=0: greedy packing keeps one non-overlapping chain" {
    try expectFamilies("AAAAAA", "AA", 0, .greedy_packing, &.{&.{ 0, 2, 4 }});
}

// Hand-derived: AAA, L=2 has only the overlapping pair 0,1.
test "AAA L=2: only the all-occurrences rule reports a family" {
    try expectFamilies("AAA", "AA", 0, .all_occurrences, &.{&.{ 0, 1 }});
    try expectFamilies("AAA", "AA", 0, .regex_union, &.{});
    try expectFamilies("AAA", "AA", 0, .maximal_chains, &.{});
    try expectFamilies("AAA", "AA", 0, .greedy_packing, &.{});
}

// Hand-derived: AAACAA, L=2, D=1 has occurrences 0,1,4. Packing takes 0 then 4 (gap 2 > D);
// the chain from 1 reaches 4 with gap 1, a valid non-overlapping family packing misses.
test "AAACAA L=2 D=1: leftmost packing misses a family the chains find" {
    try expectFamilies("AAACAA", "AA", 1, .all_occurrences, &.{&.{ 0, 1, 4 }});
    try expectFamilies("AAACAA", "AA", 1, .regex_union, &.{&.{ 1, 4 }});
    try expectFamilies("AAACAA", "AA", 1, .greedy_packing, &.{});
    try expectFamilies("AAACAA", "AA", 1, .chain_packing, &.{&.{ 1, 4 }});
    try expectFamilies("AAACAA", "AA", 1, .maximal_chains, &.{&.{ 1, 4 }});
}

test "AAAAAA L=2 D=0: chain packing keeps the leftmost chain" {
    try expectFamilies("AAAAAA", "AA", 0, .chain_packing, &.{&.{ 0, 2, 4 }});
}

// Handoff section 2.2: [100,180] and [900,980] for L=20, D=100, no overlaps, so every rule agrees.
test "non-overlapping split example agrees across rules" {
    var subject = [_]u8{'C'} ** 1000;
    const unit = "ACGTACGTTGCAAGGTTACA";
    for ([_]usize{ 100, 180, 900, 980 }) |p| @memcpy(subject[p..][0..20], unit);
    inline for (.{ Rule.all_occurrences, Rule.regex_union, Rule.maximal_chains, Rule.greedy_packing, Rule.chain_packing }) |rule| {
        try expectFamilies(&subject, unit, 100, rule, &.{ &.{ 100, 180 }, &.{ 900, 980 } });
    }
}

// Gap exactly D joins; D+1 splits.
test "gap boundary is inclusive" {
    try expectFamilies("ACxxACyyyAC", "AC", 2, .all_occurrences, &.{&.{ 0, 4 }});
    try expectFamilies("ACxxxAC", "AC", 2, .all_occurrences, &.{});
}

// Exhaustive over {A,C}^1..8, every L, D in 0..2: without overlapping members the rules coincide.
test "rules only diverge when a family has overlapping occurrences" {
    const alphabet = "AC";
    var subject: [8]u8 = undefined;
    var disagreements: usize = 0;
    var n: usize = 1;
    while (n <= subject.len) : (n += 1) {
        var code: usize = 0;
        while (code < (@as(usize, 1) << @intCast(n))) : (code += 1) {
            for (subject[0..n], 0..) |*ch, i| ch.* = alphabet[(code >> @intCast(i)) & 1];
            var len: usize = 1;
            while (len < n) : (len += 1) {
                var d: usize = 0;
                while (d <= 2) : (d += 1) {
                    const base = try families(testing.allocator, subject[0..n], len, d, .all_occurrences);
                    defer freeFamilies(testing.allocator, base);
                    if (hasOverlap(base)) continue;
                    for ([_]Rule{ .regex_union, .maximal_chains, .greedy_packing, .chain_packing }) |rule| {
                        const other = try families(testing.allocator, subject[0..n], len, d, rule);
                        defer freeFamilies(testing.allocator, other);
                        if (!sameFamilies(base, other)) disagreements += 1;
                    }
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), disagreements);
}

