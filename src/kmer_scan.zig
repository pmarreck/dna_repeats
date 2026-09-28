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
