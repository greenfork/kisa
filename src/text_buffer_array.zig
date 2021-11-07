//! Contiguous array implementation of a text buffer. The most naive and ineffective implementation,
//! it is supposed to be an experiement to identify the correct API and common patterns.
const std = @import("std");
const os = std.os;
const mem = std.mem;
const kisa = @import("kisa");
const assert = std.debug.assert;
const testing = std.testing;
const Zigstr = @import("zigstr");
const unicode = std.unicode;

pub const Contents = Zigstr;

fn utf8IsTrailing(ch: u8) bool {
    // Byte 2,3,4 are all of the form 10xxxxxx. Only the 1st byte is not allowed to start with 0b10.
    return ch >> 6 == 0b10;
}

pub const Buffer = struct {
    contents: Contents,

    const Self = @This();
    const Position = struct { line: u32, column: u32 };

    pub fn initWithFile(ally: *mem.Allocator, file: std.fs.File) !Self {
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

    pub fn initWithText(ally: *mem.Allocator, text: []const u8) !Self {
        return Self{ .contents = try Contents.fromBytes(ally, text) };
    }

    pub fn deinit(self: *Self) void {
        self.contents.deinit();
    }

    /// Return the offset of the next code point.
    pub fn nextCharOffset(self: Self, offset: usize) usize {
        // -1 for maximum offset, another -1 so we can add +1 to it.
        if (offset >= self.contents.bytes.items.len - 2) return offset;
        var result = offset + 1;
        while (utf8IsTrailing(self.contents.bytes.items[result]) and
            result < self.contents.bytes.items.len - 1)
        {
            result += 1;
        }
        return result;
    }

    /// Return the offset of the previous code point.
    pub fn prevCharOffset(self: Self, offset: usize) usize {
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
    pub fn getPosFromOffset(self: Self, offset: usize) Position {
        var line: u32 = 1;
        var column: u32 = 1;
        var off: usize = 0;
        while (off < offset and off < self.contents.bytes.items.len - 1) : (off += 1) {
            const ch = self.contents.bytes.items[off];
            column += 1;
            if (ch == '\n') {
                line += 1;
                column = 1;
            }
        }
        return Position{ .line = line, .column = column };
    }

    /// Return offset given line and column.
    pub fn getOffsetFromPos(self: Self, line: u32, column: u32) usize {
        if (line <= 0 or column <= 0) return 0;
        var lin: u32 = 1;
        var col: u32 = 1;
        var offset: usize = 0;
        while (offset < self.contents.bytes.items.len - 1) : (offset += 1) {
            if (lin == line and col == column) break;
            const ch = self.contents.bytes.items[offset];
            col += 1;
            if (ch == '\n') {
                lin += 1;
                col = 1;
            }
        }
        return offset;
    }
};

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
    try testing.expectEqual(@as(usize, 1), buffer.nextCharOffset(0));
    try testing.expectEqual(@as(usize, 2), buffer.nextCharOffset(1));
    try testing.expectEqual(@as(usize, 3), buffer.nextCharOffset(2));
    try testing.expectEqual(@as(usize, 4), buffer.nextCharOffset(3));
    try testing.expectEqual(@as(usize, 6), buffer.nextCharOffset(4)); // ý, 2 bytes
    try testing.expectEqual(@as(usize, 6), buffer.nextCharOffset(5)); // error condition
    try testing.expectEqual(@as(usize, 7), buffer.nextCharOffset(6));
    try testing.expectEqual(@as(usize, 8), buffer.nextCharOffset(7));
    try testing.expectEqual(@as(usize, 9), buffer.nextCharOffset(8));
    try testing.expectEqual(@as(usize, 9), buffer.nextCharOffset(9));
}

test "state: prevCharOffset" {
    var buffer = try Buffer.initWithText(testing.allocator, "Dobrý deň");
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.contents.bytes.items.len);
    try testing.expectEqual(@as(usize, 8), buffer.prevCharOffset(9));
    try testing.expectEqual(@as(usize, 7), buffer.prevCharOffset(8));
    try testing.expectEqual(@as(usize, 6), buffer.prevCharOffset(7));
    try testing.expectEqual(@as(usize, 4), buffer.prevCharOffset(6)); // ý, 2 bytes
    try testing.expectEqual(@as(usize, 4), buffer.prevCharOffset(5)); // error condition
    try testing.expectEqual(@as(usize, 3), buffer.prevCharOffset(4));
    try testing.expectEqual(@as(usize, 2), buffer.prevCharOffset(3));
    try testing.expectEqual(@as(usize, 1), buffer.prevCharOffset(2));
    try testing.expectEqual(@as(usize, 0), buffer.prevCharOffset(1));
    try testing.expectEqual(@as(usize, 0), buffer.prevCharOffset(0));
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
    try testing.expectEqual(Buffer.Position{ .line = 1, .column = 1 }, buffer.getPosFromOffset(0));
    try testing.expectEqual(Buffer.Position{ .line = 2, .column = 1 }, buffer.getPosFromOffset(1));
    try testing.expectEqual(Buffer.Position{ .line = 3, .column = 1 }, buffer.getPosFromOffset(2));
    try testing.expectEqual(Buffer.Position{ .line = 3, .column = 2 }, buffer.getPosFromOffset(3));
    try testing.expectEqual(Buffer.Position{ .line = 3, .column = 3 }, buffer.getPosFromOffset(4));
    try testing.expectEqual(Buffer.Position{ .line = 4, .column = 1 }, buffer.getPosFromOffset(5));
    try testing.expectEqual(Buffer.Position{ .line = 4, .column = 1 }, buffer.getPosFromOffset(999));
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
    try testing.expectEqual(@as(usize, 0), buffer.getOffsetFromPos(1, 1));
    try testing.expectEqual(@as(usize, 1), buffer.getOffsetFromPos(2, 1));
    try testing.expectEqual(@as(usize, 2), buffer.getOffsetFromPos(3, 1));
    try testing.expectEqual(@as(usize, 3), buffer.getOffsetFromPos(3, 2));
    try testing.expectEqual(@as(usize, 4), buffer.getOffsetFromPos(3, 3));
    try testing.expectEqual(@as(usize, 5), buffer.getOffsetFromPos(4, 1));
    try testing.expectEqual(@as(usize, 5), buffer.getOffsetFromPos(999, 999));
    try testing.expectEqual(@as(usize, 0), buffer.getOffsetFromPos(0, 0));
}
