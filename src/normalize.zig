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

pub const Record = struct {
    /// First word of the header line, owned (see freeRecords): parsing may run in place
    /// and overwrite the raw header bytes.
    name: []const u8,
    /// Normalized bases (A/C/G/T, ambiguity codes as N), borrowed from `out`.
    seq: []u8,
};

/// Parse FASTA: each '>' line starts a record named by its first word; sequence
/// lines follow `normalize`'s rules, except that IUPAC ambiguity codes
/// (N R Y K M S W B D H V, either case) become N, which the finder never matches.
/// Sequence bytes before the first header are an error. `out` must hold raw.len bytes and
/// may be `raw` itself: output never overtakes input. Free the result with freeRecords.
pub fn parseFasta(gpa: std.mem.Allocator, raw: []const u8, out: []u8, diag: *Diagnostic) (Error || error{ MissingHeader, OutOfMemory })![]Record {
    var records: std.ArrayList(Record) = .empty;
    errdefer {
        for (records.items) |r| gpa.free(r.name);
        records.deinit(gpa);
    }
    var n: usize = 0;
    var seq_start: usize = 0;
    var pos: usize = 0;
    while (pos < raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, pos, '\n') orelse raw.len;
        const line = raw[pos..end];
        if (line.len > 0 and line[0] == '>') {
            if (records.items.len > 0) records.items[records.items.len - 1].seq = out[seq_start..n];
            var words = std.mem.tokenizeAny(u8, line[1..], " \t\r");
            const name = try gpa.dupe(u8, words.next() orelse "");
            errdefer gpa.free(name);
            try records.append(gpa, .{ .name = name, .seq = out[n..n] });
            seq_start = n;
        } else for (line, pos..) |byte, i| {
            const clean: u8 = switch (byte) {
                ' ', '\t', '\r', 0x0b, 0x0c, '-' => continue,
                'A', 'C', 'G', 'T' => byte,
                'a', 'c', 'g', 't' => byte - ('a' - 'A'),
                'N', 'R', 'Y', 'K', 'M', 'S', 'W', 'B', 'D', 'H', 'V', 'n', 'r', 'y', 'k', 'm', 's', 'w', 'b', 'd', 'h', 'v' => 'N',
                else => {
                    diag.* = .{ .offset = i, .byte = byte };
                    return error.InvalidBase;
                },
            };
            if (records.items.len == 0) {
                diag.* = .{ .offset = i, .byte = byte };
                return error.MissingHeader;
            }
            out[n] = clean;
            n += 1;
        }
        pos = end + 1;
    }
    if (records.items.len > 0) records.items[records.items.len - 1].seq = out[seq_start..n];
    return records.toOwnedSlice(gpa);
}

pub fn freeRecords(gpa: std.mem.Allocator, records: []const Record) void {
    for (records) |r| gpa.free(r.name);
    gpa.free(records);
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

fn expectFasta(raw: []const u8, want: []const [2][]const u8) !void {
    var buf: [128]u8 = undefined;
    var diag: Diagnostic = .{};
    const recs = try parseFasta(testing.allocator, raw, &buf, &diag);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(want.len, recs.len);
    for (recs, want) |r, w| {
        try testing.expectEqualStrings(w[0], r.name);
        try testing.expectEqualStrings(w[1], r.seq);
    }
}

test "FASTA: records split at headers, name is the first word" {
    try expectFasta(">chr1 E. coli\nacgt\nAC-GT\r\n>plasmid\nGGTT\n", &.{ .{ "chr1", "ACGTACGT" }, .{ "plasmid", "GGTT" } });
    try expectFasta(">only", &.{.{ "only", "" }});
    try expectFasta("\n\n>x\tdesc\nA", &.{.{ "x", "A" }});
}

test "FASTA: IUPAC ambiguity codes become N" {
    try expectFasta(">x\nANRYKMSWBDHVnrykmswbdhv\n", &.{.{ "x", "ANNNNNNNNNNNNNNNNNNNNNN" }});
}

test "FASTA: errors keep the raw offset" {
    var buf: [64]u8 = undefined;
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidBase, parseFasta(testing.allocator, ">x\nACGU\n", &buf, &diag));
    try testing.expectEqual(@as(usize, 6), diag.offset);
    try testing.expectEqual(@as(u8, 'U'), diag.byte);
    try testing.expectError(error.MissingHeader, parseFasta(testing.allocator, "ACGT\n>x\nA", &buf, &diag));
    try testing.expectEqual(@as(usize, 0), diag.offset);
}

// Classifier over the full byte range on a sequence line.
test "FASTA: every sequence byte value is classified" {
    var base: usize = 0;
    var ambiguous: usize = 0;
    var skipped: usize = 0;
    var rejected: usize = 0;
    for (0..256) |b| {
        if (b == '\n' or b == '>') continue; // line structure, not sequence content
        var buf: [8]u8 = undefined;
        var diag: Diagnostic = .{};
        const raw = [_]u8{ '>', 'x', '\n', @intCast(b) };
        if (parseFasta(testing.allocator, &raw, &buf, &diag)) |recs| {
            defer freeRecords(testing.allocator, recs);
            const s = recs[0].seq;
            if (s.len == 0) skipped += 1 else if (s[0] == 'N') ambiguous += 1 else base += 1;
        } else |_| rejected += 1;
    }
    try testing.expectEqual(@as(usize, 8), base); // ACGTacgt
    try testing.expectEqual(@as(usize, 22), ambiguous); // NRYKMSWBDHV, both cases
    try testing.expectEqual(@as(usize, 6), skipped); // space \t \v \f \r -
    try testing.expectEqual(@as(usize, 254 - 36), rejected);
}

test "normalize works in place (output aliasing input)" {
    const raw = "acgt\nAC-GT\r\n\tGG TT";
    var buf: [raw.len]u8 = raw.*;
    var diag: Diagnostic = .{};
    try testing.expectEqualStrings("ACGTACGTGGTT", try normalize(&buf, &buf, &diag));
}

test "FASTA parsed in place keeps every record name" {
    // Later records' names sit in bytes that earlier sequence output overwrites.
    const raw = ">first one\nacgt\nACGT\n>second\nGGNN\n>third x\nTT\n";
    var buf: [raw.len]u8 = raw.*;
    var diag: Diagnostic = .{};
    const recs = try parseFasta(testing.allocator, &buf, &buf, &diag);
    defer freeRecords(testing.allocator, recs);
    try testing.expectEqual(@as(usize, 3), recs.len);
    try testing.expectEqualStrings("first", recs[0].name);
    try testing.expectEqualStrings("ACGTACGT", recs[0].seq);
    try testing.expectEqualStrings("second", recs[1].name);
    try testing.expectEqualStrings("GGNN", recs[1].seq);
    try testing.expectEqualStrings("third", recs[2].name);
    try testing.expectEqualStrings("TT", recs[2].seq);
}
