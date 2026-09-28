//! Differential check: the oracle's chain model against the production matcher, the exact
//! anchored Finder the CLI runs (capture history, DOTALL gap, compile-time anchoring, JIT).

const std = @import("std");
const c = @import("pcre2_c");
const ch = @import("pcre2_capture_history");
const fam = @import("families.zig");
const finder = @import("finder.zig");

const Api = ch.Api(8);

// Every subject over {A, C, N} up to 7 bases: N never matches a unit base but is crossed by the
// DOTALL gap, so the alphabet exercises both the unit class and the gap.
test "production finder's chain from every start equals the oracle's chain model" {
    const gpa = std.testing.allocator;
    const alphabet = "ACN";
    var subject: [7]u8 = undefined;
    var compared: usize = 0;
    var mismatches: usize = 0;

    var len: usize = 1;
    while (len <= 4) : (len += 1) {
        var d: usize = 0;
        while (d <= 2) : (d += 1) {
            const f = try finder.Finder.initAnchored(len, d);
            defer f.deinit();
            var n: usize = len + 1;
            while (n <= subject.len) : (n += 1) {
                var total: usize = 1;
                for (0..n) |_| total *= alphabet.len;
                for (0..total) |code| {
                    var x = code;
                    for (subject[0..n]) |*b| {
                        b.* = alphabet[x % alphabet.len];
                        x /= alphabet.len;
                    }
                    var start: usize = 0;
                    while (start + len <= n) : (start += 1) {
                        const model = try fam.chainAt(gpa, subject[0..n], len, d, start);
                        defer gpa.free(model);
                        const rc = c.pcre2_match_8(f.code, &subject, n, start, 0, f.md, null);
                        var engine: [16]usize = undefined;
                        var count: usize = 0;
                        if (rc > 0) {
                            for (Api.events(f.md)) |ev| {
                                if (ev.group == f.unit_group or ev.group == f.hit_group) {
                                    engine[count] = ev.start;
                                    count += 1;
                                }
                            }
                        } else if (rc != c.PCRE2_ERROR_NOMATCH) return error.MatchFailed;
                        const model_match: []const usize = if (model.len >= 2) model else &.{};
                        compared += 1;
                        if (!std.mem.eql(usize, model_match, engine[0..count])) {
                            mismatches += 1;
                            if (mismatches <= 5) std.debug.print("mismatch {s} L={d} D={d} start={d}: model {any} engine {any}\n", .{ subject[0..n], len, d, start, model_match, engine[0..count] });
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(compared > 10_000);
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}
