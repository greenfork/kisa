//! Contiguous array implementation of a text buffer. The most naive and ineffective implementation,
//! it is supposed to be an experiement to identify the correct API and common patterns.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const kisa = @import("kisa");
const Zigstr = @import("zigstr");

pub const Contents = Zigstr;

fn utf8IsTrailing(ch: u8) bool {
    // Byte 2,3,4 are all of the form 10xxxxxx. Only the 1st byte is not allowed to start with 0b10.
    return ch >> 6 == 0b10;
}

pub const Buffer = struct {
    contents: Contents,

    const Self = @This();

    pub fn initWithFile(ally: mem.Allocator, file: std.fs.File) !Self {
        const contents = file.readToEndAlloc(
            ally,
            std.math.maxInt(usize),
        ) catch |err| switch (err) {
            error.WouldBlock => unreachable,
            error.BrokenPipe => unreachable,
            error.ConnectionResetByPeer => unreachable,
            error.ConnectionTimedOut => unreachable,
            error.FileTooBig,
            error.SystemResources,
            error.IsDir,
            error.OutOfMemory,
            error.OperationAborted,
            error.NotOpenForReading,
            error.AccessDenied,
            error.InputOutput,
            error.Unexpected,
            => |e| return e,
        };
        return Self{ .contents = try Contents.fromOwnedBytes(ally, contents) };
    }

    pub fn initWithText(ally: mem.Allocator, text: []const u8) !Self {
        return Self{ .contents = try Contents.fromBytes(ally, text) };
    }

    pub fn deinit(self: *Self) void {
        self.contents.deinit();
    }

    /// Return the offset of the next code point.
    pub fn nextCodepointOffset(self: Self, offset: usize) usize {
        var result = offset;

        // Can't return `self.contents.bytes.items.len - 1` right here, the very last byte
        // could be in the middle of a codepoint.
        if (offset > self.contents.bytes.items.len - 1) result = self.contents.bytes.items.len - 1;

        if (!utf8IsTrailing(self.contents.bytes.items[result]) and
            result < self.contents.bytes.items.len - 1)
        {
            // In case we are not in the middle of a codepoint, we can advance one byte forward.
            result += 1;
        }
        while (utf8IsTrailing(self.contents.bytes.items[result])) {
            if (result < self.contents.bytes.items.len - 1) {
                result += 1;
            } else {
                // The very last byte of the buffer is an ending of a multi-byte codepoint.
                while (utf8IsTrailing(self.contents.bytes.items[result]) and result > 0) {
                    result -= 1;
                }
                return result;
            }
        }
        return result;
    }

    /// Return the offset of the previous code point.
    pub fn prevCodepointOffset(self: Self, offset: usize) usize {
        if (offset == 0) return 0;
        var result = offset - 1;
        while (utf8IsTrailing(self.contents.bytes.items[result]) and result > 0) result -= 1;
        return result;
    }

    /// Return the offset of the first character of the current line.
    pub fn beginningOfLineOffset(self: Self, offset: usize) usize {
        if (offset == 0) return 0;
        var result = offset - 1;
        while (self.contents.bytes.items[result] != '\n' and result > 0)
            result -= 1;
        if (self.contents.bytes.items[result] != '\n') {
            // The very first byte of the buffer is not a newline.
            return 0;
        } else {
            return result + 1;
        }
    }

    /// Return the offset of the ending newline character of the current line.
    pub fn endOfLineOffset(self: Self, offset: usize) usize {
        var result = offset;
        while (self.contents.bytes.items[result] != '\n' and
            result < self.contents.bytes.items.len - 1)
        {
            result += 1;
        }
        return result;
    }

    /// Return line and column given offset.
    pub fn getPosFromOffset(self: Self, offset: usize) kisa.TextBufferPosition {
        var line: u32 = 1;
        var column: u32 = 1;
        var off: usize = 0;
        while (off < offset and off < self.contents.bytes.items.len - 1) : (off += 1) {
            const ch = self.contents.bytes.items[off];
            if (utf8IsTrailing(self.contents.bytes.items[off + 1])) continue;

            column += 1;
            if (ch == '\n') {
                line += 1;
                column = 1;
            }
        }
        return .{ .line = line, .column = column };
    }

    /// Return offset given line and column.
    pub fn getOffsetFromPos(self: Self, pos: kisa.TextBufferPosition) usize {
        if (pos.line == 0 or pos.column == 0) return 0;
        var lin: u32 = 1;
        var col: u32 = 1;
        var offset: usize = 0;
        while (offset < self.contents.bytes.items.len - 1) : (offset += 1) {
            const ch = self.contents.bytes.items[offset];
            if (utf8IsTrailing(ch)) continue;

            // If ch == '\n', this means that the column is bigger than the maximum column in the
            // line.
            if (lin == pos.line and (col == pos.column or ch == '\n')) break;
            col += 1;
            if (ch == '\n') {
                lin += 1;
                col = 1;
            }
        }
        return offset;
    }

    /// Insert bytes at offset. If the offset is the length of the buffer, append to the end.
    pub fn insertBytes(self: *Self, offset: usize, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8Sequence;
        if (offset > self.contents.bytes.items.len) return error.OffsetTooBig;
        if (offset == self.contents.bytes.items.len) {
            try self.contents.bytes.appendSlice(bytes);
        } else {
            if (utf8IsTrailing(self.contents.bytes.items[offset]))
                return error.InsertAtInvalidPlace;
            try self.contents.bytes.insertSlice(offset, bytes);
        }
    }

    /// Remove bytes from start to end which are offsets in bytes pointing to the start of
    /// the code point.
    pub fn removeBytes(self: *Self, start: usize, end: usize) !void {
        if (start > end) return error.StartIsBiggerThanEnd;
        if (start >= self.contents.bytes.items.len or end >= self.contents.bytes.items.len)
            return error.StartOrEndBiggerThanBufferLength;
        if (utf8IsTrailing(self.contents.bytes.items[start]) or
            utf8IsTrailing(self.contents.bytes.items[end]))
            return error.RemoveAtInvalidPlace;
        const endlen = std.unicode.utf8ByteSequenceLength(self.contents.bytes.items[end]) catch {
            return error.RemoveAtInvalidPlace;
        };

        if (start == end and endlen == 1) {
            _ = self.contents.bytes.orderedRemove(start);
        } else {
            const newlen = self.contents.bytes.items.len + start - (end + endlen - 1) - 1;
            std.mem.copy(
                u8,
                self.contents.bytes.items[start..newlen],
                self.contents.bytes.items[end + endlen ..],
            );
            std.mem.set(u8, self.contents.bytes.items[newlen..], undefined);
            self.contents.bytes.items.len = newlen;
        }
    }

    pub fn slice(self: Self) []const u8 {
        return self.contents.bytes.items;
    }
};

const BP = kisa.TextBufferPosition;

test "state: init text buffer with file descriptor" {
    var file = try std.fs.cwd().openFile("kisarc.zzz", .{});
    defer file.close();
    var buffer = try Buffer.initWithFile(testing.allocator, file);
    defer buffer.deinit();
}

test "state: init text buffer with text" {
    var buffer = try Buffer.initWithText(testing.allocator, "Hello");
    defer buffer.deinit();
}

test "state: nextCharOffset" {
    var buffer = try Buffer.initWithText(testing.allocator, "Dobrý deň");
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.contents.bytes.items.len);
    try testing.expectEqual(@as(usize, 1), buffer.nextCodepointOffset(0));
    try testing.expectEqual(@as(usize, 2), buffer.nextCodepointOffset(1));
    try testing.expectEqual(@as(usize, 3), buffer.nextCodepointOffset(2));
    try testing.expectEqual(@as(usize, 4), buffer.nextCodepointOffset(3));
    try testing.expectEqual(@as(usize, 6), buffer.nextCodepointOffset(4)); // ý, 2 bytes
    try testing.expectEqual(@as(usize, 6), buffer.nextCodepointOffset(5)); // error condition
    try testing.expectEqual(@as(usize, 7), buffer.nextCodepointOffset(6));
    try testing.expectEqual(@as(usize, 8), buffer.nextCodepointOffset(7));
    try testing.expectEqual(@as(usize, 9), buffer.nextCodepointOffset(8));
    try testing.expectEqual(@as(usize, 9), buffer.nextCodepointOffset(9));
    try testing.expectEqual(@as(usize, 9), buffer.nextCodepointOffset(10));
    try testing.expectEqual(@as(usize, 9), buffer.nextCodepointOffset(999));
}

test "state: prevCharOffset" {
    var buffer = try Buffer.initWithText(testing.allocator, "Dobrý deň");
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.contents.bytes.items.len);
    try testing.expectEqual(@as(usize, 8), buffer.prevCodepointOffset(9));
    try testing.expectEqual(@as(usize, 7), buffer.prevCodepointOffset(8));
    try testing.expectEqual(@as(usize, 6), buffer.prevCodepointOffset(7));
    try testing.expectEqual(@as(usize, 4), buffer.prevCodepointOffset(6)); // ý, 2 bytes
    try testing.expectEqual(@as(usize, 4), buffer.prevCodepointOffset(5)); // error condition
    try testing.expectEqual(@as(usize, 3), buffer.prevCodepointOffset(4));
    try testing.expectEqual(@as(usize, 2), buffer.prevCodepointOffset(3));
    try testing.expectEqual(@as(usize, 1), buffer.prevCodepointOffset(2));
    try testing.expectEqual(@as(usize, 0), buffer.prevCodepointOffset(1));
    try testing.expectEqual(@as(usize, 0), buffer.prevCodepointOffset(0));
}

test "state: beginningOfLineOffset" {
    {
        const text =
            \\Hi
            \\Hi
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 5), buffer.contents.bytes.items.len);
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLineOffset(0));
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLineOffset(1));
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLineOffset(2));
        try testing.expectEqual(@as(usize, 3), buffer.beginningOfLineOffset(3));
        try testing.expectEqual(@as(usize, 3), buffer.beginningOfLineOffset(4));
    }
    {
        const text =
            \\
            \\
            \\Hi
            \\
            \\
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 6), buffer.contents.bytes.items.len);
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLineOffset(0));
        try testing.expectEqual(@as(usize, 1), buffer.beginningOfLineOffset(1));
        try testing.expectEqual(@as(usize, 2), buffer.beginningOfLineOffset(2));
        try testing.expectEqual(@as(usize, 2), buffer.beginningOfLineOffset(3));
        try testing.expectEqual(@as(usize, 2), buffer.beginningOfLineOffset(4));
        try testing.expectEqual(@as(usize, 5), buffer.beginningOfLineOffset(5));
    }
}

test "state: endOfLineOffset" {
    {
        const text =
            \\Hi
            \\Hi
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 5), buffer.contents.bytes.items.len);
        try testing.expectEqual(@as(usize, 2), buffer.endOfLineOffset(0));
        try testing.expectEqual(@as(usize, 2), buffer.endOfLineOffset(1));
        try testing.expectEqual(@as(usize, 2), buffer.endOfLineOffset(2));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLineOffset(3));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLineOffset(4));
    }
    {
        const text =
            \\
            \\
            \\Hi
            \\
            \\
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 6), buffer.contents.bytes.items.len);
        try testing.expectEqual(@as(usize, 0), buffer.endOfLineOffset(0));
        try testing.expectEqual(@as(usize, 1), buffer.endOfLineOffset(1));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLineOffset(2));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLineOffset(3));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLineOffset(4));
        try testing.expectEqual(@as(usize, 5), buffer.endOfLineOffset(5));
    }
}

test "state: getPosFromOffset" {
    const text =
        \\
        \\
        \\Hi
        \\
        \\
    ;
    var buffer = try Buffer.initWithText(testing.allocator, text);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 6), buffer.contents.bytes.items.len);
    try testing.expectEqual(BP{ .line = 1, .column = 1 }, buffer.getPosFromOffset(0));
    try testing.expectEqual(BP{ .line = 2, .column = 1 }, buffer.getPosFromOffset(1));
    try testing.expectEqual(BP{ .line = 3, .column = 1 }, buffer.getPosFromOffset(2));
    try testing.expectEqual(BP{ .line = 3, .column = 2 }, buffer.getPosFromOffset(3));
    try testing.expectEqual(BP{ .line = 3, .column = 3 }, buffer.getPosFromOffset(4));
    try testing.expectEqual(BP{ .line = 4, .column = 1 }, buffer.getPosFromOffset(5));
    try testing.expectEqual(BP{ .line = 4, .column = 1 }, buffer.getPosFromOffset(999));
}

test "state: getOffsetFromPos" {
    const text =
        \\
        \\
        \\Hi
        \\
        \\
    ;
    var buffer = try Buffer.initWithText(testing.allocator, text);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 6), buffer.contents.bytes.items.len);
    try testing.expectEqual(@as(usize, 0), buffer.getOffsetFromPos(BP{ .line = 1, .column = 1 }));
    try testing.expectEqual(@as(usize, 1), buffer.getOffsetFromPos(BP{ .line = 2, .column = 1 }));
    try testing.expectEqual(@as(usize, 2), buffer.getOffsetFromPos(BP{ .line = 3, .column = 1 }));
    try testing.expectEqual(@as(usize, 3), buffer.getOffsetFromPos(BP{ .line = 3, .column = 2 }));
    try testing.expectEqual(@as(usize, 4), buffer.getOffsetFromPos(BP{ .line = 3, .column = 3 }));
    try testing.expectEqual(@as(usize, 5), buffer.getOffsetFromPos(BP{ .line = 4, .column = 1 }));
    // Get the very last offset.
    try testing.expectEqual(@as(usize, 5), buffer.getOffsetFromPos(BP{ .line = 999, .column = 999 }));
    // Incorrect data lower than minimum, get the very first offset.
    try testing.expectEqual(@as(usize, 0), buffer.getOffsetFromPos(BP{ .line = 0, .column = 0 }));
    // Line contains only a single newline, column is bigger than the line has.
    try testing.expectEqual(@as(usize, 0), buffer.getOffsetFromPos(BP{ .line = 1, .column = 999 }));
    // Line has several characters, column is bigger than the line has.
    try testing.expectEqual(@as(usize, 4), buffer.getOffsetFromPos(BP{ .line = 3, .column = 999 }));
}

test "state: ofsset and pos with code points" {
    const text =
        \\
        \\hi ý
        \\h
        \\
    ;
    var buffer = try Buffer.initWithText(testing.allocator, text);
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 9), buffer.contents.bytes.items.len);

    try testing.expectEqual(BP{ .line = 1, .column = 1 }, buffer.getPosFromOffset(0));
    try testing.expectEqual(BP{ .line = 2, .column = 1 }, buffer.getPosFromOffset(1));
    try testing.expectEqual(BP{ .line = 2, .column = 2 }, buffer.getPosFromOffset(2));
    try testing.expectEqual(BP{ .line = 2, .column = 3 }, buffer.getPosFromOffset(3));
    try testing.expectEqual(BP{ .line = 2, .column = 4 }, buffer.getPosFromOffset(4));
    try testing.expectEqual(BP{ .line = 2, .column = 4 }, buffer.getPosFromOffset(5));
    try testing.expectEqual(BP{ .line = 2, .column = 5 }, buffer.getPosFromOffset(6));
    try testing.expectEqual(BP{ .line = 3, .column = 1 }, buffer.getPosFromOffset(7));
    try testing.expectEqual(BP{ .line = 3, .column = 2 }, buffer.getPosFromOffset(8));

    try testing.expectEqual(@as(usize, 0), buffer.getOffsetFromPos(BP{ .line = 1, .column = 1 }));
    try testing.expectEqual(@as(usize, 1), buffer.getOffsetFromPos(BP{ .line = 2, .column = 1 }));
    try testing.expectEqual(@as(usize, 2), buffer.getOffsetFromPos(BP{ .line = 2, .column = 2 }));
    try testing.expectEqual(@as(usize, 3), buffer.getOffsetFromPos(BP{ .line = 2, .column = 3 }));
    try testing.expectEqual(@as(usize, 4), buffer.getOffsetFromPos(BP{ .line = 2, .column = 4 }));
    try testing.expectEqual(@as(usize, 6), buffer.getOffsetFromPos(BP{ .line = 2, .column = 5 }));
    try testing.expectEqual(@as(usize, 7), buffer.getOffsetFromPos(BP{ .line = 3, .column = 1 }));
    try testing.expectEqual(@as(usize, 8), buffer.getOffsetFromPos(BP{ .line = 3, .column = 2 }));
}

test "state: insert" {
    {
        const text = "ý";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectError(error.OffsetTooBig, buffer.insertBytes(3, "u"));
        try testing.expectError(error.InsertAtInvalidPlace, buffer.insertBytes(1, "u"));
        try testing.expectError(error.InvalidUtf8Sequence, buffer.insertBytes(0, &[_]u8{0b1011_1111}));
    }
    {
        const text = "";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try buffer.insertBytes(0, "a");
        try testing.expectEqualStrings("a", buffer.slice());
        try buffer.insertBytes(0, "b");
        try testing.expectEqualStrings("ba", buffer.slice());
        try buffer.insertBytes(1, "ee");
        try testing.expectEqualStrings("beea", buffer.slice());
        try buffer.insertBytes(1, "ý");
        try testing.expectEqualStrings("býeea", buffer.slice());
        try buffer.insertBytes(1, "c");
        try testing.expectEqualStrings("bcýeea", buffer.slice());
    }
}

test "state: remove" {
    {
        const text = "ý01234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try testing.expectError(error.StartIsBiggerThanEnd, buffer.removeBytes(2, 0));
        try testing.expectError(error.StartOrEndBiggerThanBufferLength, buffer.removeBytes(0, 10));
        try testing.expectError(error.StartOrEndBiggerThanBufferLength, buffer.removeBytes(10, 10));
        try testing.expectError(error.RemoveAtInvalidPlace, buffer.removeBytes(1, 1));
        try testing.expectError(error.RemoveAtInvalidPlace, buffer.removeBytes(0, 1));
        try testing.expectError(error.RemoveAtInvalidPlace, buffer.removeBytes(1, 2));
    }
    {
        const text = "0123456789";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try buffer.removeBytes(0, 0);
        try testing.expectEqualStrings("123456789", buffer.slice());
    }
    {
        const text = "0123456789";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try buffer.removeBytes(1, 1);
        try testing.expectEqualStrings("023456789", buffer.slice());
    }
    {
        const text = "0123456789";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(0, 9);
        try testing.expectEqualStrings("", buffer.slice());
    }
    {
        const text = "0123456789";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(0, 5);
        try testing.expectEqualStrings("6789", buffer.slice());
    }
    {
        const text = "0123456789";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(5, 9);
        try testing.expectEqualStrings("01234", buffer.slice());
    }
    {
        const text = "0123456789";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(2, 7);
        try testing.expectEqualStrings("0189", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(0, 3);
        try testing.expectEqualStrings("234567", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(0, 1);
        try testing.expectEqualStrings("1234567", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(0, 0);
        try testing.expectEqualStrings("ý1234567", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(1, 1);
        try testing.expectEqualStrings("01234567", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(1, 3);
        try testing.expectEqualStrings("0234567", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(3, 3);
        try testing.expectEqualStrings("0ý234567", buffer.slice());
    }
    {
        const text = "0ý1234567";
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 10), buffer.contents.bytes.items.len);
        try buffer.removeBytes(3, 4);
        try testing.expectEqualStrings("0ý34567", buffer.slice());
    }
}
