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

    /// Return the position of the next code point.
    pub fn nextCharPos(self: Self, offset: usize) usize {
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

    /// Return the position of the previous code point.
    pub fn prevCharPos(self: Self, offset: usize) usize {
        if (offset == 0) return 0;
        var result = offset - 1;
        while (utf8IsTrailing(self.contents.bytes.items[result]) and result > 0) result -= 1;
        return result;
    }

    /// Return the position of the first character of the current line.
    pub fn beginningOfLinePos(self: Self, offset: usize) usize {
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

    /// Return the position of the ending newline character of the current line.
    pub fn endOfLinePos(self: Self, offset: usize) usize {
        var result = offset;
        while (self.contents.bytes.items[result] != '\n' and
            result < self.contents.bytes.items.len - 1)
        {
            result += 1;
        }
        return result;
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

test "state: nextCharPos" {
    var buffer = try Buffer.initWithText(testing.allocator, "Dobrý deň");
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.contents.bytes.items.len);
    try testing.expectEqual(@as(usize, 1), buffer.nextCharPos(0));
    try testing.expectEqual(@as(usize, 2), buffer.nextCharPos(1));
    try testing.expectEqual(@as(usize, 3), buffer.nextCharPos(2));
    try testing.expectEqual(@as(usize, 4), buffer.nextCharPos(3));
    try testing.expectEqual(@as(usize, 6), buffer.nextCharPos(4)); // ý, 2 bytes
    try testing.expectEqual(@as(usize, 6), buffer.nextCharPos(5)); // error condition
    try testing.expectEqual(@as(usize, 7), buffer.nextCharPos(6));
    try testing.expectEqual(@as(usize, 8), buffer.nextCharPos(7));
    try testing.expectEqual(@as(usize, 9), buffer.nextCharPos(8));
    try testing.expectEqual(@as(usize, 9), buffer.nextCharPos(9));
}

test "state: prevCharPos" {
    var buffer = try Buffer.initWithText(testing.allocator, "Dobrý deň");
    defer buffer.deinit();
    try testing.expectEqual(@as(usize, 11), buffer.contents.bytes.items.len);
    try testing.expectEqual(@as(usize, 8), buffer.prevCharPos(9));
    try testing.expectEqual(@as(usize, 7), buffer.prevCharPos(8));
    try testing.expectEqual(@as(usize, 6), buffer.prevCharPos(7));
    try testing.expectEqual(@as(usize, 4), buffer.prevCharPos(6)); // ý, 2 bytes
    try testing.expectEqual(@as(usize, 4), buffer.prevCharPos(5)); // error condition
    try testing.expectEqual(@as(usize, 3), buffer.prevCharPos(4));
    try testing.expectEqual(@as(usize, 2), buffer.prevCharPos(3));
    try testing.expectEqual(@as(usize, 1), buffer.prevCharPos(2));
    try testing.expectEqual(@as(usize, 0), buffer.prevCharPos(1));
    try testing.expectEqual(@as(usize, 0), buffer.prevCharPos(0));
}

test "state: beginningOfLinePos" {
    {
        const text =
            \\Hi
            \\Hi
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 5), buffer.contents.bytes.items.len);
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLinePos(0));
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLinePos(1));
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLinePos(2));
        try testing.expectEqual(@as(usize, 3), buffer.beginningOfLinePos(3));
        try testing.expectEqual(@as(usize, 3), buffer.beginningOfLinePos(4));
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
        try testing.expectEqual(@as(usize, 0), buffer.beginningOfLinePos(0));
        try testing.expectEqual(@as(usize, 1), buffer.beginningOfLinePos(1));
        try testing.expectEqual(@as(usize, 2), buffer.beginningOfLinePos(2));
        try testing.expectEqual(@as(usize, 2), buffer.beginningOfLinePos(3));
        try testing.expectEqual(@as(usize, 2), buffer.beginningOfLinePos(4));
        try testing.expectEqual(@as(usize, 5), buffer.beginningOfLinePos(5));
    }
}

test "state: endOfLinePos" {
    {
        const text =
            \\Hi
            \\Hi
        ;
        var buffer = try Buffer.initWithText(testing.allocator, text);
        defer buffer.deinit();
        try testing.expectEqual(@as(usize, 5), buffer.contents.bytes.items.len);
        try testing.expectEqual(@as(usize, 2), buffer.endOfLinePos(0));
        try testing.expectEqual(@as(usize, 2), buffer.endOfLinePos(1));
        try testing.expectEqual(@as(usize, 2), buffer.endOfLinePos(2));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLinePos(3));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLinePos(4));
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
        try testing.expectEqual(@as(usize, 0), buffer.endOfLinePos(0));
        try testing.expectEqual(@as(usize, 1), buffer.endOfLinePos(1));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLinePos(2));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLinePos(3));
        try testing.expectEqual(@as(usize, 4), buffer.endOfLinePos(4));
        try testing.expectEqual(@as(usize, 5), buffer.endOfLinePos(5));
    }
}
