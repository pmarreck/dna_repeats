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

    /// Compile the lazy atomic bounded-gap chain pattern for one length and gap bound.
    pub fn init(len: usize, max_gap: usize) Error!Finder {
        var buf: [160]u8 = undefined;
        const pattern = std.fmt.bufPrint(&buf, "(*CAPTURE_HISTORY)(?=(?<unit>[ACGT]{{{d}}})(?:(?>[ACGT]{{0,{d}}}?(?<hit>\\k<unit>)))++)", .{ len, max_gap }) catch return error.Compile;
        var err: c_int = 0;
        var off: usize = 0;
        const code = c.pcre2_compile_8(pattern.ptr, pattern.len, 0, &err, &off, null) orelse return error.Compile;
        errdefer c.pcre2_code_free_8(code);
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
    /// complexity: O(n) anchored match attempts; each chain step scans up to D+1 gap offsets
    /// with an O(L) backreference comparison at each.
    pub fn families(self: Finder, gpa: Allocator, subject: []const u8) Error![]fam.Family {
        var out: std.ArrayList(fam.Family) = .empty;
        errdefer {
            for (out.items) |f| gpa.free(f.positions);
            out.deinit(gpa);
        }
        var covered_until: std.StringHashMapUnmanaged(usize) = .empty;
        defer covered_until.deinit(gpa);
        var positions: std.ArrayList(usize) = .empty;
        defer positions.deinit(gpa);

        if (self.len == 0 or self.len > subject.len) return out.toOwnedSlice(gpa);
        var start: usize = 0;
        while (start + self.len <= subject.len) : (start += 1) {
            const unit = subject[start..][0..self.len];
            if (covered_until.get(unit)) |until| {
                if (start < until) continue;
            }
            const rc = c.pcre2_match_8(self.code, subject.ptr, subject.len, start, c.PCRE2_ANCHORED, self.md, null);
            if (rc == c.PCRE2_ERROR_NOMATCH) continue;
            if (rc < 0) return error.MatchFailed;
            positions.clearRetainingCapacity();
            for (Api.events(self.md)) |ev| {
                if (ev.group == self.unit_group or ev.group == self.hit_group) try positions.append(gpa, ev.start);
            }
            const last = positions.items[positions.items.len - 1];
            try covered_until.put(gpa, unit, last + self.len);
            try out.append(gpa, .{ .len = self.len, .positions = try gpa.dupe(usize, positions.items) });
        }
        return out.toOwnedSlice(gpa);
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
