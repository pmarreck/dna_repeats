//! Strict corpus cleanup from the handoff (section 1): drop ASCII whitespace and '-',
//! uppercase, then require only A/C/G/T. Anything else is an error, never silently dropped.

const std = @import("std");

pub const Error = error{InvalidBase};

pub const Diagnostic = struct {
    /// Offset of the offending byte in the raw input.
    offset: usize = 0,
    byte: u8 = 0,
};

/// Normalize `raw` into `out` (which must hold raw.len bytes); returns the used prefix.
pub fn normalize(raw: []const u8, out: []u8, diag: *Diagnostic) Error![]u8 {
    var n: usize = 0;
    for (raw, 0..) |byte, i| {
        switch (byte) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c, '-' => continue,
            'A', 'C', 'G', 'T' => out[n] = byte,
            'a', 'c', 'g', 't' => out[n] = byte - ('a' - 'A'),
            else => {
                diag.* = .{ .offset = i, .byte = byte };
                return error.InvalidBase;
            },
        }
        n += 1;
    }
    return out[0..n];
}

const testing = std.testing;

fn expectClean(raw: []const u8, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    var diag: Diagnostic = .{};
    try testing.expectEqualStrings(want, try normalize(raw, &buf, &diag));
}

fn expectRejected(raw: []const u8, offset: usize, byte: u8) !void {
    var buf: [64]u8 = undefined;
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidBase, normalize(raw, &buf, &diag));
    try testing.expectEqual(offset, diag.offset);
    try testing.expectEqual(byte, diag.byte);
}

test "removes ASCII whitespace and hyphens, uppercases" {
    try expectClean("acgt\nAC-GT\r\n\tGG TT\x0b\x0c", "ACGTACGTGGTT");
    try expectClean("", "");
    try expectClean(" \n-\t", "");
}

test "rejects any other byte with its raw offset" {
    try expectRejected("ACGN", 3, 'N');
    try expectRejected("AC\nGU", 4, 'U');
    try expectRejected("AC_GT", 2, '_');
    try expectRejected("ACG\xc3\xa9", 3, 0xc3);
    try expectRejected("AC\x00GT", 2, 0);
}

// Classifier over the full byte range: exactly these bytes are kept or skipped.
test "every byte value is classified" {
    var kept: usize = 0;
    var skipped: usize = 0;
    var rejected: usize = 0;
    for (0..256) |b| {
        var buf: [1]u8 = undefined;
        var diag: Diagnostic = .{};
        const raw = [_]u8{@intCast(b)};
        if (normalize(&raw, &buf, &diag)) |clean| {
            if (clean.len == 1) kept += 1 else skipped += 1;
        } else |_| rejected += 1;
    }
    try testing.expectEqual(@as(usize, 8), kept); // ACGTacgt
    try testing.expectEqual(@as(usize, 7), skipped); // space \t \n \v \f \r -
    try testing.expectEqual(@as(usize, 256 - 15), rejected);
}
