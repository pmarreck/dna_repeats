//! Pure-Zig candidate-start scan: the same answer as the PCRE2 existence pattern
//! `(?s)(?=([ACGT]{len}).{0,gap}?\1)` (finder.regexScanStarts), found by comparing 2-bit
//! packed k-mer codes instead of backtracking through a regex.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest unit this scan packs: 2 bits per base in a u64, leaving the top bit free so no
/// valid code equals `invalid`.
pub const max_len = 31;

/// Code of a k-mer containing a byte other than A/C/G/T: equals no valid code.
const invalid: u64 = std.math.maxInt(u64);

/// Append every offset p in [from, until), ascending, whose `len` bases are all A/C/G/T
/// and recur exactly at some q with p + len <= q <= p + len + gap (the copy must fit in
/// `subject`). Each k-mer is 2-bit packed by a rolling encoder; codes live in a sliding
/// window of O(len + gap) u64s, and each start searches the window ahead of it with a
/// vectorized scalar search.
/// complexity: O((until - from) * gap) u64 compares; memory O(len + gap).
/// The gap factor stays on purpose: an O(n) expected sliding hash window (two alternating
/// open-addressing tables, tried 2026-09-28) gave identical output but was slower where it
/// matters. One thread on E. coli K-12, user time: --crispr (gap 93) 140 ms here vs 182 ms
/// hashed; --art (gap 487) 1205 ms vs 1074 ms. A vectorized compare of a few hundred u64s
/// costs less than two hash probes and an insert per base, and --art spends its time
/// elsewhere.
pub fn scan(gpa: Allocator, subject: []const u8, len: usize, gap: usize, from: usize, until: usize, out: *std.ArrayList(usize)) Allocator.Error!void {
    std.debug.assert(len >= 1 and len <= max_len);
    if (subject.len < len) return;
    const last = subject.len - len; // last offset with a whole k-mer
    if (from > last or from >= until) return;
    const end = @min(until, last + 1); // starts are [from, end)
    const hi = @min(last, end - 1 + len + gap); // last offset whose code is needed
    const span = len + gap + 1;
    const window = try gpa.alloc(u64, @max(4 * span, 4096));
    defer gpa.free(window);
    var enc: Encoder = .{ .subject = subject, .len = len, .byte = from, .pos = from };
    var base = from; // offset of window[0]
    var filled: usize = 0;
    var p = from;
    while (p < end) : (p += 1) {
        const need = @min(hi, p + len + gap) + 1; // codes up to this offset (exclusive)
        if (need - base > window.len) {
            // Slide: keep the codes from p on at the front.
            const keep = base + filled - p;
            std.mem.copyForwards(u64, window[0..keep], window[p - base ..][0..keep]);
            base = p;
            filled = keep;
        }
        while (base + filled < need) : (filled += 1) window[filled] = enc.next();
        const code = window[p - base];
        if (code == invalid or p + len >= need) continue;
        if (std.mem.indexOfScalar(u64, window[p + len - base .. need - base], code) != null) try out.append(gpa, p);
    }
}

/// Rolling 2-bit encoder yielding the code of the k-mer at `pos`, `pos + 1`, ...
const Encoder = struct {
    subject: []const u8,
    len: usize,
    /// Next byte to consume, and the offset whose code `next` returns.
    byte: usize,
    pos: usize,
    code: u64 = 0,
    /// Consecutive A/C/G/T bytes ending just before `byte`.
    run: usize = 0,

    fn next(self: *Encoder) u64 {
        const mask = (@as(u64, 1) << @intCast(2 * self.len)) - 1;
        while (self.byte < self.pos + self.len) : (self.byte += 1) {
            const v: u64 = switch (self.subject[self.byte]) {
                'A' => 0,
                'C' => 1,
                'G' => 2,
                'T' => 3,
                else => {
                    self.run = 0;
                    continue;
                },
            };
            self.code = ((self.code << 2) | v) & mask;
            self.run += 1;
        }
        self.pos += 1;
        return if (self.run >= self.len) self.code else invalid;
    }
};
/// Reference for tests: the definition, checked directly at every start (O(n * gap)).
fn naiveStarts(gpa: Allocator, subject: []const u8, len: usize, gap: usize, from: usize, until: usize) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var p = from;
    while (p < until and p + len <= subject.len) : (p += 1) {
        const unit = subject[p..][0..len];
        if (std.mem.indexOfNone(u8, unit, "ACGT") != null) continue;
        var q = p + len;
        while (q <= p + len + gap and q + len <= subject.len) : (q += 1) {
            if (std.mem.eql(u8, unit, subject[q..][0..len])) {
                try out.append(gpa, p);
                break;
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

test "scan equals the definition across block boundaries, epoch swaps and sub-ranges" {
    const gpa = std.testing.allocator;
    const subject = try gpa.alloc(u8, 150_000);
    defer gpa.free(subject);
    var s: u64 = 7;
    // A skewed alphabet (mostly A and C, some N) makes short k-mers recur at every distance.
    for (subject) |*b| {
        s = s * 16807 % 2147483647;
        b.* = "AAAACCCGTN"[s % 10];
    }
    // The full range only at small gaps: the reference costs O(n * gap) in a Debug build.
    const ranges = [_][2]usize{ .{ 0, subject.len }, .{ 65_530, 65_540 }, .{ 64_000, 67_000 }, .{ 130_000, 132_000 }, .{ 149_000, 150_000 } };
    for ([_]usize{ 5, 9, 12 }) |len| {
        for ([_]usize{ 0, 7, 93, 487 }) |gap| {
            for (ranges, 0..) |r, ri| {
                if (ri == 0 and gap > 7) continue;
                const want = try naiveStarts(gpa, subject, len, gap, r[0], r[1]);
                defer gpa.free(want);
                var got: std.ArrayList(usize) = .empty;
                defer got.deinit(gpa);
                try got.append(gpa, 424242); // existing contents stay in place, before the new starts
                try scan(gpa, subject, len, gap, r[0], r[1], &got);
                try std.testing.expectEqual(@as(usize, 424242), got.items[0]);
                std.testing.expectEqualSlices(usize, want, got.items[1..]) catch |e| {
                    std.debug.print("len {d} gap {d} range {any}\n", .{ len, gap, r });
                    return e;
                };
            }
        }
    }
}
