//! Public buffer API, all the functions that are based on a lower-level implementation-specific
//! buffer API. Only these functions are used to operate in the editor.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const kisa = @import("kisa");
const ziglyph = @import("ziglyph");
const Buffer = @import("text_buffer_array.zig").Buffer;

comptime {
    const interface_functions = [_][]const u8{
        "initWithText",
        "byteCount",
        "byteAt",
        "codepointAt",
        "nextCodepointPosition",
        "previousCodepointPosition",
        "beginningOfLinePosition",
        "endOfLinePosition",
        "positionFromOffset",
        "positionFromLineAndColumn",
        "isNewlineAt",
        "isValidOffset",
        "firstCodepointOffset",
        "lastCodepointOffset",
        "insertBytes",
        "removeBytes",
    };
    for (interface_functions) |f| {
        if (!std.meta.trait.hasFn(f)(Buffer)) {
            @compileError("'Buffer' interface does not implement function '" ++ f ++ "'");
        }
    }
}

fn isWordCodepoint(codepoint: u21) bool {
    return ziglyph.isAlphaNum(codepoint) or codepoint == '_';
}

pub fn nextCharacter(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    return sel.moveTo(buffer.nextCodepointPosition(sel.cursor));
}

pub fn previousCharacter(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    return sel.moveTo(buffer.previousCodepointPosition(sel.cursor));
}

pub fn beginningOfLine(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    return sel.moveTo(buffer.beginningOfLinePosition(sel.cursor));
}

pub fn endOfLine(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    var pos = buffer.endOfLinePosition(sel.cursor);
    if (buffer.isNewlineAt(pos.offset) and !buffer.isNewlineAt(sel.cursor.offset)) {
        pos = buffer.previousCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn firstNonblankOfLine(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    var pos = buffer.beginningOfLinePosition(sel.cursor);
    if (!buffer.isNewlineAt(pos.offset)) {
        while (std.ascii.isSpace(buffer.byteAt(pos.offset))) pos = buffer.nextCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn beginningOfBuffer(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    return sel.moveTo(buffer.positionFromOffset(buffer.firstCodepointOffset()));
}

pub fn endOfBuffer(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    const sel = selection.resetTransients();
    return sel.moveTo(buffer.positionFromOffset(buffer.lastCodepointOffset()));
}

pub fn nextLine(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    var sel = selection;
    var pos = buffer.endOfLinePosition(sel.cursor);
    if (!buffer.isValidOffset(sel.cursor.offset) or !buffer.isValidOffset(sel.anchor.offset)) {
        sel.cursor = buffer.positionFromOffset(sel.cursor.offset);
        sel.anchor = buffer.positionFromOffset(sel.anchor.offset);
        return sel;
    }
    const last_codepoint_offset = buffer.lastCodepointOffset();

    // If current line is the last one.
    if (pos.offset == last_codepoint_offset) return sel;

    // Move to the first column of the next line.
    pos = buffer.nextCodepointPosition(pos);

    if (sel.transient_column == 0 and !sel.transient_newline) {
        if (buffer.isNewlineAt(sel.cursor.offset)) {
            sel.transient_newline = true;
        } else {
            sel.transient_column = sel.cursor.column;
        }
    }
    if (sel.transient_newline) return sel.moveTo(buffer.endOfLinePosition(pos));

    while (!buffer.isNewlineAt(pos.offset) and pos.offset != last_codepoint_offset) {
        if (pos.column == sel.transient_column and pos.line == sel.cursor.line + 1) break;
        pos = buffer.nextCodepointPosition(pos);
    }

    // Move back from a final newline in a column.
    if (buffer.isNewlineAt(pos.offset) and pos.column != 1) {
        pos = buffer.previousCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn previousLine(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    var sel = selection;
    var pos = buffer.beginningOfLinePosition(sel.cursor);
    if (!buffer.isValidOffset(sel.cursor.offset) or !buffer.isValidOffset(sel.anchor.offset)) {
        sel.cursor = buffer.positionFromOffset(sel.cursor.offset);
        sel.anchor = buffer.positionFromOffset(sel.anchor.offset);
        return sel;
    }

    // If current line is the first one.
    if (pos.offset == buffer.firstCodepointOffset()) return sel;

    // Move to the last column of the previous line, we know that it is a newline.
    pos = buffer.previousCodepointPosition(pos);

    if (sel.transient_column == 0 and !sel.transient_newline) {
        if (buffer.isNewlineAt(sel.cursor.offset)) {
            sel.transient_newline = true;
        } else {
            sel.transient_column = sel.cursor.column;
        }
    }
    if (sel.transient_newline) return sel.moveTo(pos);

    while (pos.column != 1) {
        if (pos.column == sel.transient_column and pos.line == sel.cursor.line - 1) break;
        pos = buffer.previousCodepointPosition(pos);
    }

    // Move back from a final newline in a column.
    if (buffer.isNewlineAt(pos.offset) and pos.column != 1) {
        pos = buffer.previousCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn beginningOfNextWord(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    var sel = selection.resetTransients();
    var pos = sel.cursor;
    const last_codepoint_offset = buffer.lastCodepointOffset();
    if (!buffer.isValidOffset(pos.offset)) pos = buffer.positionFromOffset(pos.offset);
    while (isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != last_codepoint_offset)
    {
        pos = buffer.nextCodepointPosition(pos);
    }
    while (!isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != last_codepoint_offset)
    {
        pos = buffer.nextCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn endOfPreviousWord(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    var sel = selection.resetTransients();
    var pos = sel.cursor;
    const first_codepoint_offset = buffer.firstCodepointOffset();
    if (!buffer.isValidOffset(pos.offset)) pos = buffer.positionFromOffset(pos.offset);
    while (isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != first_codepoint_offset)
    {
        pos = buffer.previousCodepointPosition(pos);
    }
    while (!isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != first_codepoint_offset)
    {
        pos = buffer.previousCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn beginningOfWord(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    var sel = selection.resetTransients();
    var pos = sel.cursor;
    const first_codepoint_offset = buffer.firstCodepointOffset();
    if (!buffer.isValidOffset(pos.offset)) pos = buffer.positionFromOffset(pos.offset);
    const previous_pos = buffer.previousCodepointPosition(pos);
    // When cursor is currently at the beginning of word.
    if (!isWordCodepoint(buffer.codepointAt(previous_pos.offset) catch unreachable)) {
        pos = previous_pos;
    }
    while (!isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != first_codepoint_offset)
    {
        pos = buffer.previousCodepointPosition(pos);
    }
    while (isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != first_codepoint_offset)
    {
        pos = buffer.previousCodepointPosition(pos);
    }
    if (!isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable)) {
        pos = buffer.nextCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn endOfWord(buffer: Buffer, selection: kisa.Selection) kisa.Selection {
    var sel = selection.resetTransients();
    var pos = sel.cursor;
    const last_codepoint_offset = buffer.lastCodepointOffset();
    if (!buffer.isValidOffset(pos.offset)) pos = buffer.positionFromOffset(pos.offset);
    const next_pos = buffer.nextCodepointPosition(pos);
    // When cursor is currently at the end of word.
    if (!isWordCodepoint(buffer.codepointAt(next_pos.offset) catch unreachable)) {
        pos = next_pos;
    }
    while (!isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != last_codepoint_offset)
    {
        pos = buffer.nextCodepointPosition(pos);
    }
    while (isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable) and
        pos.offset != last_codepoint_offset)
    {
        pos = buffer.nextCodepointPosition(pos);
    }
    if (!isWordCodepoint(buffer.codepointAt(pos.offset) catch unreachable)) {
        pos = buffer.previousCodepointPosition(pos);
    }
    return sel.moveTo(pos);
}

pub fn insertCharacter(buffer: *Buffer, selection: kisa.Selection, codepoint: u21) !kisa.Selection {
    var sel = selection.resetTransients();
    var bytes: [4]u8 = undefined;
    const bytes_len = try std.unicode.utf8Encode(codepoint, &bytes);
    try buffer.insertBytes(sel.cursor.offset, bytes[0..bytes_len]);
    const pos = kisa.Selection.Position{
        .offset = sel.cursor.offset + bytes_len,
        .line = sel.cursor.line,
        .column = sel.cursor.column + 1,
    };
    return sel.moveTo(pos);
}

pub fn insertNewline(buffer: *Buffer, selection: kisa.Selection) !kisa.Selection {
    var sel = selection.resetTransients();
    const newline = buffer.line_ending.str();
    try buffer.insertBytes(sel.cursor.offset, newline);
    const pos = kisa.Selection.Position{
        .offset = sel.cursor.offset + @intCast(kisa.Selection.Offset, newline.len),
        .line = sel.cursor.line + 1,
        .column = 1,
    };
    return sel.moveTo(pos);
}

pub fn removeCharacterForward(buffer: *Buffer, selection: kisa.Selection) !kisa.Selection {
    var sel = selection.resetTransients();
    var pos = selection.cursor;
    if (!buffer.isValidOffset(pos.offset)) pos = buffer.positionFromOffset(pos.offset);
    const bytes_len = std.unicode.utf8ByteSequenceLength(buffer.byteAt(pos.offset)) catch unreachable;
    try buffer.removeBytes(pos.offset, pos.offset + bytes_len - 1);
    return sel;
}

fn s(position: kisa.Selection.Position) kisa.Selection {
    return .{ .cursor = position, .anchor = position };
}
fn sc(position: kisa.Selection.Position, transient_column: kisa.Selection.Dimension) kisa.Selection {
    return .{ .cursor = position, .anchor = position, .transient_column = transient_column };
}
fn sn(position: kisa.Selection.Position) kisa.Selection {
    return .{ .cursor = position, .anchor = position, .transient_newline = true };
}
const text =
    \\Dobrý
    \\deň
;
const p0 = kisa.Selection.Position{ .offset = 0, .line = 1, .column = 1 }; // D
const p1 = kisa.Selection.Position{ .offset = 1, .line = 1, .column = 2 }; // o
const p2 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 }; // b
const p3 = kisa.Selection.Position{ .offset = 3, .line = 1, .column = 4 }; // r
const p4 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 }; // ý
const p5 = kisa.Selection.Position{ .offset = 5, .line = 1, .column = 5 }; // middle of ý
const p6 = kisa.Selection.Position{ .offset = 6, .line = 1, .column = 6 }; // \n
const p7 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 1 }; // d
const p8 = kisa.Selection.Position{ .offset = 8, .line = 2, .column = 2 }; // e
const p9 = kisa.Selection.Position{ .offset = 9, .line = 2, .column = 3 }; // ň
const p10 = kisa.Selection.Position{ .offset = 10, .line = 2, .column = 3 }; // middle of ň
const p11 = kisa.Selection.Position{ .offset = 11, .line = 2, .column = 3 }; // past the length

const s0 = s(p0);
const s1 = s(p1);
const s2 = s(p2);
const s3 = s(p3);
const s4 = s(p4);
const s5 = s(p5);
const s6 = s(p6);
const s7 = s(p7);
const s8 = s(p8);
const s9 = s(p9);
const s10 = s(p10);
const s11 = s(p11);

test "buffer: nextCharacter" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    try testing.expectEqual(s1, nextCharacter(buffer, s0));
    try testing.expectEqual(s2, nextCharacter(buffer, s1));
    try testing.expectEqual(s3, nextCharacter(buffer, s2));
    try testing.expectEqual(s4, nextCharacter(buffer, s3));
    try testing.expectEqual(s6, nextCharacter(buffer, s4));
    try testing.expectEqual(s6, nextCharacter(buffer, s5));
    try testing.expectEqual(s7, nextCharacter(buffer, s6));
    try testing.expectEqual(s8, nextCharacter(buffer, s7));
    try testing.expectEqual(s9, nextCharacter(buffer, s8));
    try testing.expectEqual(s9, nextCharacter(buffer, s9));
    try testing.expectEqual(s9, nextCharacter(buffer, s10));
    try testing.expectEqual(s9, nextCharacter(buffer, s11));
}

test "buffer: previousCharacter" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    try testing.expectEqual(s9, previousCharacter(buffer, s11));
    try testing.expectEqual(s9, previousCharacter(buffer, s10));
    try testing.expectEqual(s8, previousCharacter(buffer, s9));
    try testing.expectEqual(s7, previousCharacter(buffer, s8));
    try testing.expectEqual(s6, previousCharacter(buffer, s7));
    try testing.expectEqual(s4, previousCharacter(buffer, s6));
    try testing.expectEqual(s4, previousCharacter(buffer, s5));
    try testing.expectEqual(s3, previousCharacter(buffer, s4));
    try testing.expectEqual(s2, previousCharacter(buffer, s3));
    try testing.expectEqual(s1, previousCharacter(buffer, s2));
    try testing.expectEqual(s0, previousCharacter(buffer, s1));
    try testing.expectEqual(s0, previousCharacter(buffer, s0));
}

test "buffer: beginningOfLine" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    try testing.expectEqual(s0, beginningOfLine(buffer, s0));
    try testing.expectEqual(s0, beginningOfLine(buffer, s1));
    try testing.expectEqual(s0, beginningOfLine(buffer, s2));
    try testing.expectEqual(s0, beginningOfLine(buffer, s3));
    try testing.expectEqual(s0, beginningOfLine(buffer, s4));
    try testing.expectEqual(s0, beginningOfLine(buffer, s5));
    try testing.expectEqual(s0, beginningOfLine(buffer, s6));
    try testing.expectEqual(s7, beginningOfLine(buffer, s7));
    try testing.expectEqual(s7, beginningOfLine(buffer, s8));
    try testing.expectEqual(s7, beginningOfLine(buffer, s9));
    try testing.expectEqual(s7, beginningOfLine(buffer, s10));
    try testing.expectEqual(s7, beginningOfLine(buffer, s11));
}

test "buffer: endOfLine" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    try testing.expectEqual(s4, endOfLine(buffer, s0));
    try testing.expectEqual(s4, endOfLine(buffer, s1));
    try testing.expectEqual(s4, endOfLine(buffer, s2));
    try testing.expectEqual(s4, endOfLine(buffer, s3));
    try testing.expectEqual(s4, endOfLine(buffer, s4));
    try testing.expectEqual(s4, endOfLine(buffer, s5));
    try testing.expectEqual(s6, endOfLine(buffer, s6));
    try testing.expectEqual(s9, endOfLine(buffer, s7));
    try testing.expectEqual(s9, endOfLine(buffer, s8));
    try testing.expectEqual(s9, endOfLine(buffer, s9));
    try testing.expectEqual(s9, endOfLine(buffer, s10));
    try testing.expectEqual(s9, endOfLine(buffer, s11));
}

test "buffer: firstNonblankOfLine" {
    const text2 =
        \\0123
        \\ 123
        \\  23
        \\
        \\
    ;
    var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
    defer buffer.deinit();
    const c1 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
    const c2 = kisa.Selection.Position{ .offset = 5, .line = 2, .column = 1 };
    const c3 = kisa.Selection.Position{ .offset = 13, .line = 3, .column = 4 };
    const c4 = kisa.Selection.Position{ .offset = 15, .line = 4, .column = 1 };

    const a1 = kisa.Selection.Position{ .offset = 0, .line = 1, .column = 1 };
    const a2 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 2 };
    const a3 = kisa.Selection.Position{ .offset = 12, .line = 3, .column = 3 };
    const a4 = kisa.Selection.Position{ .offset = 15, .line = 4, .column = 1 };
    try testing.expectEqual(@as(usize, 16), buffer.byteCount());
    try testing.expectEqual(s(a1), firstNonblankOfLine(buffer, s(c1)));
    try testing.expectEqual(s(a2), firstNonblankOfLine(buffer, s(c2)));
    try testing.expectEqual(s(a3), firstNonblankOfLine(buffer, s(c3)));
    try testing.expectEqual(s(a4), firstNonblankOfLine(buffer, s(c4)));
}

test "buffer: beginningOfBuffer" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s0));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s1));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s2));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s3));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s4));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s5));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s6));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s7));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s8));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s9));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s10));
    try testing.expectEqual(s0, beginningOfBuffer(buffer, s11));
}

test "buffer: endOfBuffer" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    try testing.expectEqual(s9, endOfBuffer(buffer, s0));
    try testing.expectEqual(s9, endOfBuffer(buffer, s1));
    try testing.expectEqual(s9, endOfBuffer(buffer, s2));
    try testing.expectEqual(s9, endOfBuffer(buffer, s3));
    try testing.expectEqual(s9, endOfBuffer(buffer, s4));
    try testing.expectEqual(s9, endOfBuffer(buffer, s5));
    try testing.expectEqual(s9, endOfBuffer(buffer, s6));
    try testing.expectEqual(s9, endOfBuffer(buffer, s7));
    try testing.expectEqual(s9, endOfBuffer(buffer, s8));
    try testing.expectEqual(s9, endOfBuffer(buffer, s9));
    try testing.expectEqual(s9, endOfBuffer(buffer, s10));
    try testing.expectEqual(s9, endOfBuffer(buffer, s11));
}

test "buffer: nextLine" {
    {
        // Basic behavior.
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        try testing.expectEqual(sc(p7, 1), nextLine(buffer, s0));
        try testing.expectEqual(sc(p8, 2), nextLine(buffer, s1));
        try testing.expectEqual(sc(p9, 3), nextLine(buffer, s2));
        try testing.expectEqual(sc(p9, 4), nextLine(buffer, s3));
        try testing.expectEqual(sc(p9, 5), nextLine(buffer, s4));
        try testing.expectEqual(sc(p6, 0), nextLine(buffer, s5));
        try testing.expectEqual(sn(p9), nextLine(buffer, s6));
        try testing.expectEqual(s7, nextLine(buffer, s7));
        try testing.expectEqual(s8, nextLine(buffer, s8));
        try testing.expectEqual(s9, nextLine(buffer, s9));
        try testing.expectEqual(s9, nextLine(buffer, s10));
        try testing.expectEqual(s9, nextLine(buffer, s11));
    }
    {
        // Transient column.
        const text2 =
            \\0123
            \\01
            \\
            \\01
            \\012345
            \\0123
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 23), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 };
        const c2 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 2 };
        const c3 = kisa.Selection.Position{ .offset = 8, .line = 3, .column = 1 };
        const c4 = kisa.Selection.Position{ .offset = 10, .line = 4, .column = 2 };
        const c5 = kisa.Selection.Position{ .offset = 14, .line = 5, .column = 3 };
        const c6 = kisa.Selection.Position{ .offset = 21, .line = 6, .column = 3 };
        try testing.expectEqual(sc(c2, 3), nextLine(buffer, s(c1)));
        try testing.expectEqual(sc(c3, 3), nextLine(buffer, sc(c2, 3)));
        try testing.expectEqual(sc(c4, 3), nextLine(buffer, sc(c3, 3)));
        try testing.expectEqual(sc(c5, 3), nextLine(buffer, sc(c4, 3)));
        try testing.expectEqual(sc(c6, 3), nextLine(buffer, sc(c5, 3)));
    }
    {
        // Transient newline.
        const text2 =
            \\0123
            \\01
            \\
            \\01
            \\012345
            \\0123
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 23), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
        const c2 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 3 };
        const c3 = kisa.Selection.Position{ .offset = 8, .line = 3, .column = 1 };
        const c4 = kisa.Selection.Position{ .offset = 11, .line = 4, .column = 3 };
        const c5 = kisa.Selection.Position{ .offset = 18, .line = 5, .column = 7 };
        const c6 = kisa.Selection.Position{ .offset = 22, .line = 6, .column = 4 };
        try testing.expectEqual(sn(c2), nextLine(buffer, s(c1)));
        try testing.expectEqual(sn(c3), nextLine(buffer, sn(c2)));
        try testing.expectEqual(sn(c4), nextLine(buffer, sn(c3)));
        try testing.expectEqual(sn(c5), nextLine(buffer, sn(c4)));
        try testing.expectEqual(sn(c6), nextLine(buffer, sn(c5)));
    }
}

test "buffer: previousLine" {
    {
        // Basic behavior.
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        try testing.expectEqual(s0, previousLine(buffer, s0));
        try testing.expectEqual(s1, previousLine(buffer, s1));
        try testing.expectEqual(s2, previousLine(buffer, s2));
        try testing.expectEqual(s3, previousLine(buffer, s3));
        try testing.expectEqual(s4, previousLine(buffer, s4));
        try testing.expectEqual(s6, previousLine(buffer, s5));
        try testing.expectEqual(s6, previousLine(buffer, s6));
        try testing.expectEqual(sc(p0, 1), previousLine(buffer, s7));
        try testing.expectEqual(sc(p1, 2), previousLine(buffer, s8));
        try testing.expectEqual(sc(p2, 3), previousLine(buffer, s9));
        try testing.expectEqual(s9, previousLine(buffer, s10));
        try testing.expectEqual(s9, previousLine(buffer, s11));
    }
    {
        // Transient column.
        const text2 =
            \\0123
            \\01
            \\
            \\01
            \\012345
            \\0123
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 23), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 };
        const c2 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 2 };
        const c3 = kisa.Selection.Position{ .offset = 8, .line = 3, .column = 1 };
        const c4 = kisa.Selection.Position{ .offset = 10, .line = 4, .column = 2 };
        const c5 = kisa.Selection.Position{ .offset = 14, .line = 5, .column = 3 };
        const c6 = kisa.Selection.Position{ .offset = 21, .line = 6, .column = 3 };
        try testing.expectEqual(sc(c5, 3), previousLine(buffer, s(c6)));
        try testing.expectEqual(sc(c4, 3), previousLine(buffer, sc(c5, 3)));
        try testing.expectEqual(sc(c3, 3), previousLine(buffer, sc(c4, 3)));
        try testing.expectEqual(sc(c2, 3), previousLine(buffer, sc(c3, 3)));
        try testing.expectEqual(sc(c1, 3), previousLine(buffer, sc(c2, 3)));
    }
    {
        // Transient newline.
        const text2 =
            \\0123
            \\01
            \\
            \\01
            \\012345
            \\0123
            \\
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 24), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
        const c2 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 3 };
        const c3 = kisa.Selection.Position{ .offset = 8, .line = 3, .column = 1 };
        const c4 = kisa.Selection.Position{ .offset = 11, .line = 4, .column = 3 };
        const c5 = kisa.Selection.Position{ .offset = 18, .line = 5, .column = 7 };
        const c6 = kisa.Selection.Position{ .offset = 23, .line = 6, .column = 4 };
        try testing.expectEqual(sn(c5), previousLine(buffer, s(c6)));
        try testing.expectEqual(sn(c4), previousLine(buffer, sn(c5)));
        try testing.expectEqual(sn(c3), previousLine(buffer, sn(c4)));
        try testing.expectEqual(sn(c2), previousLine(buffer, sn(c3)));
        try testing.expectEqual(sn(c1), previousLine(buffer, sn(c2)));
        try testing.expectEqual(sn(c1), previousLine(buffer, sn(c1)));
    }
}

test "buffer: beginningOfNextWord" {
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s0));
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s1));
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s2));
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s3));
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s4));
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s5));
        try testing.expectEqual(s7, beginningOfNextWord(buffer, s6));
        try testing.expectEqual(s9, beginningOfNextWord(buffer, s7));
        try testing.expectEqual(s9, beginningOfNextWord(buffer, s8));
        try testing.expectEqual(s9, beginningOfNextWord(buffer, s9));
        try testing.expectEqual(s9, beginningOfNextWord(buffer, s10));
        try testing.expectEqual(s9, beginningOfNextWord(buffer, s11));
    }
    {
        const text2 = "a ab \nabc\n a";
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 12), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 0, .line = 1, .column = 1 };
        const c2 = kisa.Selection.Position{ .offset = 1, .line = 1, .column = 2 };
        const c3 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 };
        const c4 = kisa.Selection.Position{ .offset = 3, .line = 1, .column = 4 };
        const c5 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
        const c6 = kisa.Selection.Position{ .offset = 5, .line = 1, .column = 6 };
        const c7 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 1 };
        const c8 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 2 };
        const c9 = kisa.Selection.Position{ .offset = 8, .line = 2, .column = 3 };
        const c10 = kisa.Selection.Position{ .offset = 9, .line = 2, .column = 4 };
        const c11 = kisa.Selection.Position{ .offset = 10, .line = 3, .column = 1 };
        const c12 = kisa.Selection.Position{ .offset = 11, .line = 3, .column = 2 };
        try testing.expectEqual(s(c3), beginningOfNextWord(buffer, s(c1)));
        try testing.expectEqual(s(c3), beginningOfNextWord(buffer, s(c2)));
        try testing.expectEqual(s(c7), beginningOfNextWord(buffer, s(c3)));
        try testing.expectEqual(s(c7), beginningOfNextWord(buffer, s(c4)));
        try testing.expectEqual(s(c7), beginningOfNextWord(buffer, s(c5)));
        try testing.expectEqual(s(c7), beginningOfNextWord(buffer, s(c6)));
        try testing.expectEqual(s(c12), beginningOfNextWord(buffer, s(c7)));
        try testing.expectEqual(s(c12), beginningOfNextWord(buffer, s(c8)));
        try testing.expectEqual(s(c12), beginningOfNextWord(buffer, s(c9)));
        try testing.expectEqual(s(c12), beginningOfNextWord(buffer, s(c10)));
        try testing.expectEqual(s(c12), beginningOfNextWord(buffer, s(c11)));
        try testing.expectEqual(s(c12), beginningOfNextWord(buffer, s(c12)));
    }
}

test "buffer: endOfWord" {
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        try testing.expectEqual(s4, endOfWord(buffer, s0));
        try testing.expectEqual(s4, endOfWord(buffer, s1));
        try testing.expectEqual(s4, endOfWord(buffer, s2));
        try testing.expectEqual(s4, endOfWord(buffer, s3));
        try testing.expectEqual(s9, endOfWord(buffer, s4));
        try testing.expectEqual(s9, endOfWord(buffer, s5));
        try testing.expectEqual(s9, endOfWord(buffer, s6));
        try testing.expectEqual(s9, endOfWord(buffer, s7));
        try testing.expectEqual(s9, endOfWord(buffer, s8));
        try testing.expectEqual(s9, endOfWord(buffer, s9));
        try testing.expectEqual(s9, endOfWord(buffer, s10));
        try testing.expectEqual(s9, endOfWord(buffer, s11));
    }
    {
        const text2 = "a ab \nabc\n a";
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 12), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 0, .line = 1, .column = 1 };
        const c2 = kisa.Selection.Position{ .offset = 1, .line = 1, .column = 2 };
        const c3 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 };
        const c4 = kisa.Selection.Position{ .offset = 3, .line = 1, .column = 4 };
        const c5 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
        const c6 = kisa.Selection.Position{ .offset = 5, .line = 1, .column = 6 };
        const c7 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 1 };
        const c8 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 2 };
        const c9 = kisa.Selection.Position{ .offset = 8, .line = 2, .column = 3 };
        const c10 = kisa.Selection.Position{ .offset = 9, .line = 2, .column = 4 };
        const c11 = kisa.Selection.Position{ .offset = 10, .line = 3, .column = 1 };
        const c12 = kisa.Selection.Position{ .offset = 11, .line = 3, .column = 2 };
        try testing.expectEqual(s(c4), endOfWord(buffer, s(c1)));
        try testing.expectEqual(s(c4), endOfWord(buffer, s(c2)));
        try testing.expectEqual(s(c4), endOfWord(buffer, s(c3)));
        try testing.expectEqual(s(c9), endOfWord(buffer, s(c4)));
        try testing.expectEqual(s(c9), endOfWord(buffer, s(c5)));
        try testing.expectEqual(s(c9), endOfWord(buffer, s(c6)));
        try testing.expectEqual(s(c9), endOfWord(buffer, s(c7)));
        try testing.expectEqual(s(c9), endOfWord(buffer, s(c8)));
        try testing.expectEqual(s(c12), endOfWord(buffer, s(c9)));
        try testing.expectEqual(s(c12), endOfWord(buffer, s(c10)));
        try testing.expectEqual(s(c12), endOfWord(buffer, s(c11)));
        try testing.expectEqual(s(c12), endOfWord(buffer, s(c12)));
    }
}

test "buffer: beginningOfWord" {
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        try testing.expectEqual(s0, beginningOfWord(buffer, s0));
        try testing.expectEqual(s0, beginningOfWord(buffer, s1));
        try testing.expectEqual(s0, beginningOfWord(buffer, s2));
        try testing.expectEqual(s0, beginningOfWord(buffer, s3));
        try testing.expectEqual(s0, beginningOfWord(buffer, s4));
        try testing.expectEqual(s0, beginningOfWord(buffer, s5));
        try testing.expectEqual(s0, beginningOfWord(buffer, s6));
        try testing.expectEqual(s0, beginningOfWord(buffer, s7));
        try testing.expectEqual(s7, beginningOfWord(buffer, s8));
        try testing.expectEqual(s7, beginningOfWord(buffer, s9));
        try testing.expectEqual(s7, beginningOfWord(buffer, s10));
        try testing.expectEqual(s7, beginningOfWord(buffer, s11));
    }
    {
        const text2 = "a ab \nabc\n a";
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 12), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 0, .line = 1, .column = 1 };
        const c2 = kisa.Selection.Position{ .offset = 1, .line = 1, .column = 2 };
        const c3 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 };
        const c4 = kisa.Selection.Position{ .offset = 3, .line = 1, .column = 4 };
        const c5 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
        const c6 = kisa.Selection.Position{ .offset = 5, .line = 1, .column = 6 };
        const c7 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 1 };
        const c8 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 2 };
        const c9 = kisa.Selection.Position{ .offset = 8, .line = 2, .column = 3 };
        const c10 = kisa.Selection.Position{ .offset = 9, .line = 2, .column = 4 };
        const c11 = kisa.Selection.Position{ .offset = 10, .line = 3, .column = 1 };
        const c12 = kisa.Selection.Position{ .offset = 11, .line = 3, .column = 2 };
        try testing.expectEqual(s(c1), beginningOfWord(buffer, s(c1)));
        try testing.expectEqual(s(c1), beginningOfWord(buffer, s(c2)));
        try testing.expectEqual(s(c1), beginningOfWord(buffer, s(c3)));
        try testing.expectEqual(s(c3), beginningOfWord(buffer, s(c4)));
        try testing.expectEqual(s(c3), beginningOfWord(buffer, s(c5)));
        try testing.expectEqual(s(c3), beginningOfWord(buffer, s(c6)));
        try testing.expectEqual(s(c3), beginningOfWord(buffer, s(c7)));
        try testing.expectEqual(s(c7), beginningOfWord(buffer, s(c8)));
        try testing.expectEqual(s(c7), beginningOfWord(buffer, s(c9)));
        try testing.expectEqual(s(c7), beginningOfWord(buffer, s(c10)));
        try testing.expectEqual(s(c7), beginningOfWord(buffer, s(c11)));
        try testing.expectEqual(s(c7), beginningOfWord(buffer, s(c12)));
    }
}

test "buffer: endOfPreviousWord" {
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        try testing.expectEqual(s0, endOfPreviousWord(buffer, s0));
        try testing.expectEqual(s0, endOfPreviousWord(buffer, s1));
        try testing.expectEqual(s0, endOfPreviousWord(buffer, s2));
        try testing.expectEqual(s0, endOfPreviousWord(buffer, s3));
        try testing.expectEqual(s0, endOfPreviousWord(buffer, s4));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s5));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s6));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s7));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s8));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s9));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s10));
        try testing.expectEqual(s4, endOfPreviousWord(buffer, s11));
    }
    {
        const text2 = "a ab \nabc\n a";
        var buffer = try Buffer.initWithText(testing.allocator, text2, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 12), buffer.byteCount());
        const c1 = kisa.Selection.Position{ .offset = 0, .line = 1, .column = 1 };
        const c2 = kisa.Selection.Position{ .offset = 1, .line = 1, .column = 2 };
        const c3 = kisa.Selection.Position{ .offset = 2, .line = 1, .column = 3 };
        const c4 = kisa.Selection.Position{ .offset = 3, .line = 1, .column = 4 };
        const c5 = kisa.Selection.Position{ .offset = 4, .line = 1, .column = 5 };
        const c6 = kisa.Selection.Position{ .offset = 5, .line = 1, .column = 6 };
        const c7 = kisa.Selection.Position{ .offset = 6, .line = 2, .column = 1 };
        const c8 = kisa.Selection.Position{ .offset = 7, .line = 2, .column = 2 };
        const c9 = kisa.Selection.Position{ .offset = 8, .line = 2, .column = 3 };
        const c10 = kisa.Selection.Position{ .offset = 9, .line = 2, .column = 4 };
        const c11 = kisa.Selection.Position{ .offset = 10, .line = 3, .column = 1 };
        const c12 = kisa.Selection.Position{ .offset = 11, .line = 3, .column = 2 };
        try testing.expectEqual(s(c1), endOfPreviousWord(buffer, s(c1)));
        try testing.expectEqual(s(c1), endOfPreviousWord(buffer, s(c2)));
        try testing.expectEqual(s(c1), endOfPreviousWord(buffer, s(c3)));
        try testing.expectEqual(s(c1), endOfPreviousWord(buffer, s(c4)));
        try testing.expectEqual(s(c4), endOfPreviousWord(buffer, s(c5)));
        try testing.expectEqual(s(c4), endOfPreviousWord(buffer, s(c6)));
        try testing.expectEqual(s(c4), endOfPreviousWord(buffer, s(c7)));
        try testing.expectEqual(s(c4), endOfPreviousWord(buffer, s(c8)));
        try testing.expectEqual(s(c4), endOfPreviousWord(buffer, s(c9)));
        try testing.expectEqual(s(c9), endOfPreviousWord(buffer, s(c10)));
        try testing.expectEqual(s(c9), endOfPreviousWord(buffer, s(c11)));
        try testing.expectEqual(s(c9), endOfPreviousWord(buffer, s(c12)));
    }
}

test "buffer: insertCharacter" {
    var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.byteCount());
    const c1 = try insertCharacter(&buffer, s0, 'a');
    try testing.expectEqualStrings("a" ++ text, buffer.slice());
    try testing.expectEqual(s1, c1);
    const c2 = try insertCharacter(&buffer, s1, try std.unicode.utf8Decode("ý"));
    try testing.expectEqualStrings("aý" ++ text, buffer.slice());
    try testing.expectEqual(s(.{ .offset = 3, .line = 1, .column = 3 }), c2);
}

test "buffer: insertNewline" {
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .unix);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        const c1 = try insertNewline(&buffer, s0);
        try testing.expectEqualStrings("\n" ++ text, buffer.slice());
        try testing.expectEqual(s(.{ .offset = 1, .line = 2, .column = 1 }), c1);
    }
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .old_mac);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        const c1 = try insertNewline(&buffer, s0);
        try testing.expectEqualStrings("\r" ++ text, buffer.slice());
        try testing.expectEqual(s(.{ .offset = 1, .line = 2, .column = 1 }), c1);
    }
    {
        var buffer = try Buffer.initWithText(testing.allocator, text, .dos);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 11), buffer.byteCount());
        const c1 = try insertNewline(&buffer, s0);
        try testing.expectEqualStrings("\r\n" ++ text, buffer.slice());
        try testing.expectEqual(s(.{ .offset = 2, .line = 2, .column = 1 }), c1);
    }
}

test "buffer: removeCharacterForward" {
    {
        const text2 = "abc\r\nd";
        var buffer = try Buffer.initWithText(testing.allocator, text2, .dos);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 6), buffer.byteCount());
        const c1 = try removeCharacterForward(&buffer, s0);
        try testing.expectEqualStrings("bc\r\nd", buffer.slice());
        try testing.expectEqual(s0, c1);
        const c2 = try removeCharacterForward(&buffer, s0);
        try testing.expectEqualStrings("c\r\nd", buffer.slice());
        try testing.expectEqual(s0, c2);
        const c3 = try removeCharacterForward(&buffer, s0);
        try testing.expectEqualStrings("\r\nd", buffer.slice());
        try testing.expectEqual(s0, c3);
        const c4 = try removeCharacterForward(&buffer, s0);
        try testing.expectEqualStrings("d", buffer.slice());
        try testing.expectEqual(s0, c4);
        const c5 = try removeCharacterForward(&buffer, s0);
        try testing.expectEqualStrings("", buffer.slice());
        try testing.expectEqual(s0, c5);
    }
}
