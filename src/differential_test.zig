//! Differential check: the oracle's chain model against the real fixed-L PCRE2 regex with capture history.

const std = @import("std");
const c = @import("pcre2_c");
const ch = @import("pcre2_capture_history");
const fam = @import("families.zig");

const Api = ch.Api(8);

/// The handoff's fixed-length lazy atomic bounded-gap pattern (section 8.1).
fn buildPattern(buf: []u8, len: usize, max_gap: usize) ![]u8 {
    return std.fmt.bufPrint(buf, "(?=(?<unit>[ACGT]{{{d}}})(?:(?>[ACGT]{{0,{d}}}?(?<hit>\\k<unit>)))++)", .{ len, max_gap });
}

test "engine chain from every start equals the oracle's chain model" {
    const gpa = std.testing.allocator;
    const alphabet = "AC";
    var subject: [9]u8 = undefined;
    var pattern_buf: [128]u8 = undefined;
    var compared: usize = 0;
    var mismatches: usize = 0;

    var len: usize = 1;
    while (len <= 4) : (len += 1) {
        var d: usize = 0;
        while (d <= 2) : (d += 1) {
            const pattern = try buildPattern(&pattern_buf, len, d);
            var err: c_int = 0;
            var off: usize = 0;
            const code = c.pcre2_compile_8(pattern.ptr, pattern.len, 0, &err, &off, null) orelse return error.Compile;
            defer c.pcre2_code_free_8(code);
            const md = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return error.OutOfMemory;
            defer c.pcre2_match_data_free_8(md);
            const unit_group: u32 = @intCast(c.pcre2_substring_number_from_name_8(code, "unit"));
            const hit_group: u32 = @intCast(c.pcre2_substring_number_from_name_8(code, "hit"));

            var n: usize = len + 1;
            while (n <= subject.len) : (n += 1) {
                var bits: usize = 0;
                while (bits < (@as(usize, 1) << @intCast(n))) : (bits += 1) {
                    for (subject[0..n], 0..) |*x, i| x.* = alphabet[(bits >> @intCast(i)) & 1];
                    var start: usize = 0;
                    while (start + len <= n) : (start += 1) {
                        const model = try fam.chainAt(gpa, subject[0..n], len, d, start);
                        defer gpa.free(model);
                        const rc = c.pcre2_match_8(code, &subject, n, start, c.PCRE2_ANCHORED | ch.option, md, null);
                        var engine: [16]usize = undefined;
                        var count: usize = 0;
                        if (rc > 0) {
                            for (Api.events(md)) |ev| {
                                if (ev.group == unit_group or ev.group == hit_group) {
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
