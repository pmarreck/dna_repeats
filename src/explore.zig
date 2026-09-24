//! Exhaustively enumerate small subjects and report where candidate family rules disagree.
//! Usage: explore [max_len=8] [alphabet=AC] [max_gap=2]

const std = @import("std");
const fam = @import("families.zig");

const rules = [_]fam.Rule{ .all_occurrences, .regex_union, .maximal_chains, .greedy_packing, .chain_packing };
const pair_count = rules.len * (rules.len - 1) / 2;

const Example = struct {
    subject: []u8,
    len: usize,
    max_gap: usize,
};

fn printFamilies(w: *std.Io.Writer, fams: []const fam.Family) !void {
    if (fams.len == 0) try w.writeAll(" (none)");
    for (fams) |f| try w.print(" {any}", .{f.positions});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const max_len: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 8;
    const alphabet: []const u8 = if (args.len > 2) args[2] else "AC";
    const max_gap: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 2;

    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buf);
    const w = &file_writer.interface;

    var differ = [_]usize{0} ** pair_count;
    var first = [_]?Example{null} ** pair_count;
    var overlap_cases = [_]usize{0} ** rules.len;
    var total: usize = 0;
    var disagree_without_overlap: usize = 0;
    var no_overlap_example: ?Example = null;

    const subject = try gpa.alloc(u8, max_len);
    defer gpa.free(subject);
    var n: usize = 1;
    while (n <= max_len) : (n += 1) {
        var code: usize = 0;
        const combos = std.math.pow(usize, alphabet.len, n);
        while (code < combos) : (code += 1) {
            var c = code;
            for (subject[0..n]) |*ch| {
                ch.* = alphabet[c % alphabet.len];
                c /= alphabet.len;
            }
            var len: usize = 1;
            while (len < n) : (len += 1) {
                var d: usize = 0;
                while (d <= max_gap) : (d += 1) {
                    total += 1;
                    var results: [rules.len][]fam.Family = undefined;
                    for (rules, 0..) |rule, i| results[i] = try fam.families(gpa, subject[0..n], len, d, rule);
                    defer for (results) |r| fam.freeFamilies(gpa, r);
                    for (results, 0..) |r, i| {
                        if (fam.hasOverlap(r)) overlap_cases[i] += 1;
                    }
                    const overlap_free = !fam.hasOverlap(results[0]);
                    var all_same = true;
                    for (results[1..]) |r| all_same = all_same and fam.sameFamilies(results[0], r);
                    if (overlap_free and !all_same) {
                        disagree_without_overlap += 1;
                        if (no_overlap_example == null) no_overlap_example = .{ .subject = try gpa.dupe(u8, subject[0..n]), .len = len, .max_gap = d };
                    }
                    var k: usize = 0;
                    for (0..rules.len) |i| {
                        for (i + 1..rules.len) |j| {
                            if (!fam.sameFamilies(results[i], results[j])) {
                                differ[k] += 1;
                                if (first[k] == null) first[k] = .{ .subject = try gpa.dupe(u8, subject[0..n]), .len = len, .max_gap = d };
                            }
                            k += 1;
                        }
                    }
                }
            }
        }
    }

    try w.print("# Rule divergence: alphabet {s}, lengths 1..{d}, D 0..{d}, {d} (subject, L, D) cases\n\n", .{ alphabet, max_len, max_gap, total });
    try w.writeAll("## Families containing overlapping members\n\n");
    for (rules, overlap_cases) |rule, count| try w.print("- {s}: {d} cases\n", .{ @tagName(rule), count });
    try w.print("\nCases with no overlapping occurrences where any rules disagree: {d}", .{disagree_without_overlap});
    if (no_overlap_example) |ex| {
        try w.print("; e.g. \"{s}\" L={d} D={d}\n", .{ ex.subject, ex.len, ex.max_gap });
        for (rules) |rule| {
            const fams = try fam.families(gpa, ex.subject, ex.len, ex.max_gap, rule);
            defer fam.freeFamilies(gpa, fams);
            try w.print("  - {s}:", .{@tagName(rule)});
            try printFamilies(w, fams);
            try w.writeAll("\n");
        }
        gpa.free(ex.subject);
    } else try w.writeAll("\n");
    try w.writeAll("\n## Pairwise disagreement (shortest example first found)\n\n");
    var k: usize = 0;
    for (0..rules.len) |i| {
        for (i + 1..rules.len) |j| {
            try w.print("- {s} vs {s}: {d} cases", .{ @tagName(rules[i]), @tagName(rules[j]), differ[k] });
            if (first[k]) |ex| {
                try w.print("; e.g. \"{s}\" L={d} D={d}\n", .{ ex.subject, ex.len, ex.max_gap });
                for ([_]usize{ i, j }) |r| {
                    const fams = try fam.families(gpa, ex.subject, ex.len, ex.max_gap, rules[r]);
                    defer fam.freeFamilies(gpa, fams);
                    try w.print("  - {s}:", .{@tagName(rules[r])});
                    try printFamilies(w, fams);
                    try w.writeAll("\n");
                }
                gpa.free(ex.subject);
            } else try w.writeAll("\n");
            k += 1;
        }
    }
    try w.flush();
}
