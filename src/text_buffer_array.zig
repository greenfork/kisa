//! Contiguous array implementation of a text buffer. The most naive and ineffective implementation,
//! it is supposed to be an experiement to identify the correct API and common patterns.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const kisa = @import("kisa");

pub const Contents = std.ArrayList(u8);

/// Implementation of the core functionality of the "text buffer" as a contiguous array buffer.
pub const Buffer = struct {
    contents: Contents,
    line_ending: kisa.LineEnding,

    const Self = @This();

    pub fn initWithFile(ally: mem.Allocator, file: std.fs.File, line_ending: kisa.LineEnding) !Self {
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
        return Self{
            .contents = Contents.fromOwnedSlice(ally, contents),
            .line_ending = line_ending,
        };
    }

    pub fn initWithText(ally: mem.Allocator, text: []const u8, line_ending: kisa.LineEnding) !Self {
        var contents = try Contents.initCapacity(ally, text.len);
        contents.appendSliceAssumeCapacity(text);
        return Self{
            .contents = contents,
            .line_ending = line_ending,
        };
    }

    pub fn deinit(self: *Self) void {
        self.contents.deinit();
    }

    pub fn byteCount(self: Self) kisa.Selection.Offset {
        return @intCast(kisa.Selection.Offset, self.contents.items.len);
    }

    pub fn byteAt(self: Self, offset: kisa.Selection.Offset) u8 {
        if (offset < self.byteCount()) {
            return self.contents.items[offset];
        } else {
            return 0;
        }
    }

    pub fn codepointAt(self: Self, offset: kisa.Selection.Offset) !u21 {
        return switch (try std.unicode.utf8ByteSequenceLength(self.byteAt(offset))) {
            1 => @as(u21, self.byteAt(offset)),
            2 => std.unicode.utf8Decode2(self.byteSlice(offset, offset + 2) catch unreachable),
            3 => std.unicode.utf8Decode3(self.byteSlice(offset, offset + 3) catch unreachable),
            4 => std.unicode.utf8Decode4(self.byteSlice(offset, offset + 4) catch unreachable),
            else => unreachable,
        };
    }

    pub fn byteSlice(self: Self, start: usize, end: usize) ![]const u8 {
        if (start > end) return error.StartIsBiggerThanEnd;
        if (start >= self.byteCount()) return error.StartBiggerThanBufferLength;
        if (end > self.byteCount()) return error.EndBiggerThanBufferLength;
        return self.contents.items[start..end];
    }

    pub fn slice(self: Self) []const u8 {
        return self.contents.items[0..];
    }

    pub fn nextCodepointPosition(self: Self, position: kisa.Selection.Position) kisa.Selection.Position {
        if (self.byteCount() == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        const should_recount = position.line == 0 or position.column == 0;
        const last_codepoint_offset = self.lastCodepointOffset();
        if (position.offset > last_codepoint_offset) {
            // Offset is bigger than buffer length, we assume that `position` is incorrect
            // completely, so we re-count it completely.
            return self.positionFromOffset(last_codepoint_offset);
        } else if (position.offset == last_codepoint_offset) {
            // Already the last character of the buffer.
            if (should_recount) {
                return self.positionFromOffset(last_codepoint_offset);
            } else {
                return position;
            }
            unreachable;
        } else if (utf8IsTrailing(self.byteAt(position.offset))) {
            // Offset is in the middle of a codepoint, we move to the next closest valid
            // codepoint offset and re-count position.
            var next_valid_offset = position.offset;
            while (utf8IsTrailing(self.byteAt(next_valid_offset))) next_valid_offset += 1;
            return self.positionFromOffset(next_valid_offset);
        } else if (self.newlineStartsAt(position.offset)) {
            const increment: kisa.Selection.Offset = if (self.line_ending == .dos) 2 else 1;
            if (should_recount) {
                return self.positionFromOffset(position.offset + increment);
            } else {
                return .{ .offset = position.offset + increment, .line = position.line + 1, .column = 1 };
            }
            unreachable;
        } else if (self.line_ending == .dos and position.offset > 0 and
            self.byteAt(position.offset - 1) == '\r' and self.byteAt(position.offset) == '\n')
        {
            // Offset is at \n which is not correct, it should be on \r, so we re-count position.
            return self.positionFromOffset(position.offset + 1);
        } else {
            var next_valid_offset = position.offset + 1;
            while (utf8IsTrailing(self.byteAt(next_valid_offset))) next_valid_offset += 1;
            if (should_recount) {
                return self.positionFromOffset(next_valid_offset);
            } else {
                return .{ .offset = next_valid_offset, .line = position.line, .column = position.column + 1 };
            }
            unreachable;
        }
        unreachable;
    }

    pub fn previousCodepointPosition(self: Self, position: kisa.Selection.Position) kisa.Selection.Position {
        if (self.byteCount() == 0 or position.offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        const should_recount = position.line == 0 or position.column == 0;
        const last_codepoint_offset = self.lastCodepointOffset();
        if (position.offset > last_codepoint_offset) {
            // Offset is bigger than buffer length, we assume that `position` is incorrect
            // completely, so we re-count it completely.
            return self.positionFromOffset(last_codepoint_offset);
        } else if (utf8IsTrailing(self.byteAt(position.offset))) {
            // Offset is in the middle of a codepoint, we move to the previous closest valid
            // codepoint offset and re-count position.
            var previous_valid_offset = position.offset;
            while (utf8IsTrailing(self.byteAt(previous_valid_offset))) previous_valid_offset -= 1;
            return self.positionFromOffset(previous_valid_offset);
        } else if (self.newlineEndsAt(position.offset - 1)) {
            const decrement: kisa.Selection.Offset = if (self.line_ending == .dos) 2 else 1;
            const new_offset = position.offset - decrement;
            if (should_recount) {
                return self.positionFromOffset(new_offset);
            } else {
                return .{
                    .offset = new_offset,
                    .line = position.line - 1,
                    .column = self.getMaxColumnFromOffset(new_offset),
                };
            }
            unreachable;
        } else {
            var previous_valid_offset = position.offset - 1;
            while (utf8IsTrailing(self.byteAt(previous_valid_offset))) previous_valid_offset -= 1;
            if (should_recount) {
                return self.positionFromOffset(previous_valid_offset);
            } else {
                return .{
                    .offset = previous_valid_offset,
                    .line = position.line,
                    .column = position.column - 1,
                };
            }
            unreachable;
        }
        unreachable;
    }

    pub fn beginningOfLinePosition(self: Self, position: kisa.Selection.Position) kisa.Selection.Position {
        if (self.byteCount() == 0 or position.offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        const last_codepoint_offset = self.lastCodepointOffset();
        if (last_codepoint_offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        const should_recount = position.line == 0 or position.column == 0;
        var off = position.offset - 1;
        if (position.offset > last_codepoint_offset) off = last_codepoint_offset;
        while (off > 0) : (off -= 1) {
            if (self.newlineEndsAt(off)) break;
        }
        if (self.byteAt(off) != '\n' and (self.line_ending == .unix or self.line_ending == .dos) or
            self.byteAt(off) != '\r' and self.line_ending == .old_mac)
        {
            // The very first byte of the buffer is not a newline.
            return .{ .offset = 0, .line = 1, .column = 1 };
        } else if (should_recount) {
            return self.positionFromOffset(off + 1);
        } else {
            return .{ .offset = off + 1, .line = position.line, .column = 1 };
        }
        unreachable;
    }

    pub fn endOfLinePosition(self: Self, position: kisa.Selection.Position) kisa.Selection.Position {
        if (self.byteCount() == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        const last_codepoint_offset = self.lastCodepointOffset();
        if (last_codepoint_offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        var should_recount = position.line == 0 or position.column == 0;
        if (position.offset > last_codepoint_offset) {
            return self.positionFromOffset(last_codepoint_offset);
        } else if (position.offset == last_codepoint_offset) {
            if (should_recount) {
                return self.positionFromOffset(last_codepoint_offset);
            } else {
                return position;
            }
            unreachable;
        } else {
            var off = position.offset;
            if (utf8IsTrailing(self.byteAt(off))) {
                should_recount = true;
                while (utf8IsTrailing(self.byteAt(off)) and off < last_codepoint_offset) off += 1;
            }
            var added_columns: u32 = 0;
            while (off < last_codepoint_offset) : (off += std.unicode.utf8ByteSequenceLength(self.byteAt(off)) catch unreachable) {
                if (self.newlineStartsAt(off)) break;
                added_columns += 1;
            }
            if (should_recount) {
                return self.positionFromOffset(off);
            } else {
                return .{ .offset = off, .line = position.line, .column = position.column + added_columns };
            }
            unreachable;
        }
        unreachable;
    }

    pub fn positionFromOffset(self: Self, offset: kisa.Selection.Offset) kisa.Selection.Position {
        if (self.byteCount() == 0 or offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        const last_codepoint_offset = self.lastCodepointOffset();
        if (last_codepoint_offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        var line: u32 = 1;
        var column: u32 = 1;
        var off: kisa.Selection.Offset = 0;
        // Correction in case offset is at \n which is incorrect position for DOS newline.
        const limit = blk: {
            if (self.line_ending == .dos and offset < self.byteCount() and
                self.byteAt(offset) == '\n' and offset > 0)
            {
                break :blk offset - 1;
            } else {
                break :blk offset;
            }
        };
        while (off < limit and off < last_codepoint_offset) : (off += std.unicode.utf8ByteSequenceLength(self.byteAt(off)) catch unreachable) {
            if (self.newlineStartsAt(off)) {
                line += 1;
                column = 1;
                // In \r\n DOS newline we don't count \n as a new column.
            } else if (!(self.byteAt(off) == '\n' and self.line_ending == .dos)) {
                column += 1;
            }
        }
        return .{ .offset = off, .line = line, .column = column };
    }

    pub fn positionFromLineAndColumn(
        self: Self,
        line: kisa.Selection.Dimension,
        column: kisa.Selection.Dimension,
    ) kisa.Selection.Position {
        if (self.byteCount() == 0 or (line <= 1 and column <= 1))
            return .{ .offset = 0, .line = 1, .column = 1 };
        const last_codepoint_offset = self.lastCodepointOffset();
        if (last_codepoint_offset == 0) return .{ .offset = 0, .line = 1, .column = 1 };
        var lin: kisa.Selection.Dimension = 1;
        var col: kisa.Selection.Dimension = 1;
        var off: kisa.Selection.Offset = 0;
        while (off < last_codepoint_offset) : (off += std.unicode.utf8ByteSequenceLength(self.byteAt(off)) catch unreachable) {
            // In \r\n DOS newline we don't count \n as a new column.
            if (self.byteAt(off) == '\n' and self.line_ending == .dos and off < last_codepoint_offset) off += 1;

            // If byte is newline, this means that the column is bigger than the maximum column in the line.
            if (lin == line and (col == column or self.newlineStartsAt(off))) break;

            if (self.newlineStartsAt(off)) {
                lin += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .offset = off, .line = lin, .column = col };
    }

    /// Insert bytes at offset. If the offset is the length of the buffer, append to the end.
    pub fn insertBytes(self: *Self, offset: kisa.Selection.Offset, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8Sequence;
        if (offset > self.byteCount()) return error.OffsetTooBig;
        if (offset == self.byteCount()) {
            try self.contents.appendSlice(bytes);
        } else {
            if (utf8IsTrailing(self.byteAt(offset))) return error.MiddleOfCodepoint;
            if (self.byteAt(offset) == '\n' and self.line_ending == .dos)
                return error.MiddleOfDosNewline;
            try self.contents.insertSlice(offset, bytes);
        }
    }

    /// Remove bytes from start to end which are offsets in bytes pointing to the start of
    /// the code point.
    pub fn removeBytes(self: *Self, start: kisa.Selection.Offset, end: kisa.Selection.Offset) !void {
        if (start > end) return error.StartIsBiggerThanEnd;
        if (start >= self.byteCount()) return error.StartBiggerThanBufferLength;
        if (end >= self.byteCount()) return error.EndBiggerThanBufferLength;
        if (utf8IsTrailing(self.byteAt(start))) return error.MiddleOfCodepointAtStart;
        if (utf8IsTrailing(self.byteAt(end))) return error.MiddleOfCodepointAtEnd;
        if (self.byteAt(start) == '\n' and self.line_ending == .dos)
            return error.MiddleOfDosNewlineAtStart;
        if (self.byteAt(end) == '\n' and self.line_ending == .dos)
            return error.MiddleOfDosNewlineAtEnd;
        const endlen = blk: {
            if (self.byteAt(end) == '\r' and self.line_ending == .dos) {
                break :blk 2; // \r\n
            } else {
                break :blk std.unicode.utf8ByteSequenceLength(self.byteAt(end)) catch unreachable;
            }
        };

        if (start == end and endlen == 1) {
            _ = self.contents.orderedRemove(start);
        } else {
            const newlen = self.byteCount() + start - (end + endlen - 1) - 1;
            std.mem.copy(
                u8,
                self.contents.items[start..newlen],
                self.contents.items[end + endlen ..],
            );
            std.mem.set(u8, self.contents.items[newlen..], undefined);
            self.contents.items.len = newlen;
        }
    }

    pub fn isNewlineAt(self: Self, offset: kisa.Selection.Offset) bool {
        return self.newlineStartsAt(offset);
    }

    pub fn firstCodepointOffset(self: Self) kisa.Selection.Offset {
        _ = self;
        return 0;
    }
    pub fn lastCodepointOffset(self: Self) kisa.Selection.Offset {
        if (self.byteCount() == 0) return 0;
        var result = self.byteCount() - 1;
        while (result > 0 and utf8IsTrailing(self.byteAt(result))) result -= 1;
        if (result > 0 and self.line_ending == .dos and
            self.byteAt(result) == '\n' and self.byteAt(result - 1) == '\r')
        {
            result -= 1;
        }
        return result;
    }

    pub fn isValidOffset(self: Self, offset: kisa.Selection.Offset) bool {
        const last_codepoint_offset = self.lastCodepointOffset();
        const invalid = offset > last_codepoint_offset or
            utf8IsTrailing(self.byteAt(offset)) or
            self.byteAt(offset) == '\n' and self.line_ending == .dos;
        return !invalid;
    }

    fn newlineStartsAt(self: Self, offset: kisa.Selection.Offset) bool {
        return self.byteAt(offset) == '\n' and self.line_ending == .unix or
            self.byteAt(offset) == '\r' and self.line_ending == .old_mac or
            self.byteAt(offset) == '\r' and self.line_ending == .dos and
            offset + 1 < self.byteCount() and self.byteAt(offset + 1) == '\n';
    }
    fn newlineEndsAt(self: Self, offset: kisa.Selection.Offset) bool {
        return self.byteAt(offset) == '\n' and self.line_ending == .unix or
            self.byteAt(offset) == '\r' and self.line_ending == .old_mac or
            self.byteAt(offset) == '\n' and self.line_ending == .dos and
            offset - 1 >= 0 and self.byteAt(offset - 1) == '\r';
    }
    fn getMaxColumnFromOffset(self: Self, offset: kisa.Selection.Offset) kisa.Selection.Dimension {
        var off = self.beginningOfLinePosition(.{ .offset = offset, .line = 1, .column = 1 }).offset;
        var result: kisa.Selection.Dimension = 1;
        const last_codepoint_offset = self.lastCodepointOffset();
        while (off < last_codepoint_offset) : (off += std.unicode.utf8ByteSequenceLength(self.byteAt(off)) catch unreachable) {
            if (self.newlineStartsAt(off)) break;
            result += 1;
        }
        return result;
    }
    fn utf8IsTrailing(ch: u8) bool {
        // Bytes 2, 3, 4 in a multi-byte codepoint are all of the form 10xxxxxx. Only the 1st
        // byte is not allowed to start with 0b10.
        return ch >> 6 == 0b10;
    }
};

const SP = kisa.Selection.Position;

test "buffer: reference everything" {
    std.testing.refAllDecls(Buffer);
}

test "buffer: init text buffer with file descriptor" {
    var file = try std.fs.cwd().openFile("kisarc.zzz", .{});
    defer file.close();
    var b = try Buffer.initWithFile(testing.allocator, file, .unix);
    defer b.deinit();
}

test "buffer: init text buffer with text" {
    var b = try Buffer.initWithText(testing.allocator, "Hello", .unix);
    defer b.deinit();
}

test "buffer: nextCodepointPosition" {
    {
        var b = try Buffer.initWithText(testing.allocator, "Dobrý deň", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 11), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 1, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 3 }, b.nextCodepointPosition(.{ .offset = 1, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 1, .column = 4 }, b.nextCodepointPosition(.{ .offset = 2, .line = 1, .column = 3 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 1, .column = 5 }, b.nextCodepointPosition(.{ .offset = 3, .line = 1, .column = 4 }));
        try testing.expectEqual(SP{ .offset = 6, .line = 1, .column = 6 }, b.nextCodepointPosition(.{ .offset = 4, .line = 1, .column = 5 })); // ý
        try testing.expectEqual(SP{ .offset = 6, .line = 1, .column = 6 }, b.nextCodepointPosition(.{ .offset = 5, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 7, .line = 1, .column = 7 }, b.nextCodepointPosition(.{ .offset = 6, .line = 1, .column = 6 }));
        try testing.expectEqual(SP{ .offset = 8, .line = 1, .column = 8 }, b.nextCodepointPosition(.{ .offset = 7, .line = 1, .column = 7 }));
        try testing.expectEqual(SP{ .offset = 9, .line = 1, .column = 9 }, b.nextCodepointPosition(.{ .offset = 8, .line = 1, .column = 8 }));
        try testing.expectEqual(SP{ .offset = 9, .line = 1, .column = 9 }, b.nextCodepointPosition(.{ .offset = 9, .line = 1, .column = 9 })); // ň
        try testing.expectEqual(SP{ .offset = 9, .line = 1, .column = 9 }, b.nextCodepointPosition(.{ .offset = 10, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 9, .line = 1, .column = 9 }, b.nextCodepointPosition(.{ .offset = 11, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ýý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 4), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 1, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 2, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 3, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 4, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.nextCodepointPosition(.{ .offset = 5, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 1, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.nextCodepointPosition(.{ .offset = 1, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n1\n\n2\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.nextCodepointPosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.nextCodepointPosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.nextCodepointPosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r\n1\r\n\r\n2\r\n", .dos);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.nextCodepointPosition(.{ .offset = 1, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.nextCodepointPosition(.{ .offset = 2, .line = 2, .column = 1 })); // 1
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.nextCodepointPosition(.{ .offset = 3, .line = 2, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.nextCodepointPosition(.{ .offset = 4, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.nextCodepointPosition(.{ .offset = 5, .line = 3, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.nextCodepointPosition(.{ .offset = 6, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 7, .line = 4, .column = 1 })); // 2
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 8, .line = 4, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 9, .line = 0, .column = 0 })); // \n
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r1\r\r2\r", .old_mac);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.nextCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.nextCodepointPosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.nextCodepointPosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.nextCodepointPosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.nextCodepointPosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
}

test "buffer: previousCodepointPosition" {
    {
        var b = try Buffer.initWithText(testing.allocator, "Dobrý deň", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 11), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 9, .line = 1, .column = 9 }, b.previousCodepointPosition(.{ .offset = 11, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 9, .line = 1, .column = 9 }, b.previousCodepointPosition(.{ .offset = 10, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 8, .line = 1, .column = 8 }, b.previousCodepointPosition(.{ .offset = 9, .line = 1, .column = 9 })); // ň
        try testing.expectEqual(SP{ .offset = 7, .line = 1, .column = 7 }, b.previousCodepointPosition(.{ .offset = 8, .line = 1, .column = 8 }));
        try testing.expectEqual(SP{ .offset = 6, .line = 1, .column = 6 }, b.previousCodepointPosition(.{ .offset = 7, .line = 1, .column = 7 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 1, .column = 5 }, b.previousCodepointPosition(.{ .offset = 6, .line = 1, .column = 6 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 1, .column = 5 }, b.previousCodepointPosition(.{ .offset = 5, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 1, .column = 4 }, b.previousCodepointPosition(.{ .offset = 4, .line = 1, .column = 5 })); // ý
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 3 }, b.previousCodepointPosition(.{ .offset = 3, .line = 1, .column = 4 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 1, .column = 2 }, b.previousCodepointPosition(.{ .offset = 2, .line = 1, .column = 3 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 2, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ýý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 4), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 2, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.previousCodepointPosition(.{ .offset = 3, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.previousCodepointPosition(.{ .offset = 4, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.previousCodepointPosition(.{ .offset = 5, .line = 1, .column = 2 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n1\n\n2\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.previousCodepointPosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.previousCodepointPosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.previousCodepointPosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.previousCodepointPosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r\n1\r\n\r\n2\r\n", .dos);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 0, .line = 1, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 2, .line = 2, .column = 1 })); // 1
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.previousCodepointPosition(.{ .offset = 3, .line = 2, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.previousCodepointPosition(.{ .offset = 4, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.previousCodepointPosition(.{ .offset = 5, .line = 3, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.previousCodepointPosition(.{ .offset = 6, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.previousCodepointPosition(.{ .offset = 7, .line = 4, .column = 1 })); // 2
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.previousCodepointPosition(.{ .offset = 8, .line = 4, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.previousCodepointPosition(.{ .offset = 9, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.previousCodepointPosition(.{ .offset = 10, .line = 0, .column = 0 })); // past
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r1\r\r2\r", .old_mac);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.previousCodepointPosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.previousCodepointPosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.previousCodepointPosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.previousCodepointPosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.previousCodepointPosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
}

test "buffer: beginningOfLinePosition" {
    {
        const text =
            \\Hi
            \\Hi
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 5), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 1, .column = 3 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 4, .line = 2, .column = 2 }));
    }
    {
        const text =
            \\
            \\
            \\Hi
            \\
            \\
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 3, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 4, .line = 3, .column = 3 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 5, .line = 4, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ýý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 4), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 4, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 5, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n1\n\n2\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r\n1\r\n\r\n2\r\n", .dos);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 2, .column = 1 })); // 1
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 2, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 4, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 5, .line = 3, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 6, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 7, .line = 4, .column = 1 })); // 2
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 8, .line = 4, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 9, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 10, .line = 0, .column = 0 })); // past
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r1\r\r2\r", .old_mac);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.beginningOfLinePosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
}

test "buffer: endOfLinePosition" {
    {
        const text =
            \\Hi
            \\Hi
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 5), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 3 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 3 }, b.endOfLinePosition(.{ .offset = 1, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 3 }, b.endOfLinePosition(.{ .offset = 2, .line = 1, .column = 3 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 3, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 4, .line = 2, .column = 2 }));
    }
    {
        const text =
            \\
            \\
            \\Hi
            \\
            \\
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 1, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 1, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 1, .column = 3 }, b.endOfLinePosition(.{ .offset = 2, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 1, .column = 3 }, b.endOfLinePosition(.{ .offset = 3, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 4, .line = 1, .column = 3 }, b.endOfLinePosition(.{ .offset = 4, .line = 1, .column = 3 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 5, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 2, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 3, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "ýý", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 4), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.endOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.endOfLinePosition(.{ .offset = 2, .line = 1, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.endOfLinePosition(.{ .offset = 3, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.endOfLinePosition(.{ .offset = 4, .line = 0, .column = 0 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.endOfLinePosition(.{ .offset = 5, .line = 0, .column = 0 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 1, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 1, .line = 1, .column = 1 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n1\n\n2\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.endOfLinePosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r\n1\r\n\r\n2\r\n", .dos);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 1, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 2, .line = 2, .column = 1 })); // 1
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 3, .line = 2, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.endOfLinePosition(.{ .offset = 4, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.endOfLinePosition(.{ .offset = 5, .line = 3, .column = 1 })); // \r
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 6, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 7, .line = 4, .column = 1 })); // 2
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 8, .line = 4, .column = 2 })); // \r
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 9, .line = 0, .column = 0 })); // \n
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 10, .line = 0, .column = 0 })); // past
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r1\r\r2\r", .old_mac);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.endOfLinePosition(.{ .offset = 0, .line = 1, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 1, .line = 2, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.endOfLinePosition(.{ .offset = 2, .line = 2, .column = 2 }));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.endOfLinePosition(.{ .offset = 3, .line = 3, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 4, .line = 4, .column = 1 }));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.endOfLinePosition(.{ .offset = 5, .line = 4, .column = 2 }));
    }
}

test "buffer: positionFromOffset" {
    {
        const text =
            \\
            \\
            \\Hi
            \\
            \\
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromOffset(1));
        try testing.expectEqual(SP{ .offset = 2, .line = 3, .column = 1 }, b.positionFromOffset(2));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 2 }, b.positionFromOffset(3));
        try testing.expectEqual(SP{ .offset = 4, .line = 3, .column = 3 }, b.positionFromOffset(4));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 1 }, b.positionFromOffset(5));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 1 }, b.positionFromOffset(999));
    }
    {
        const text =
            \\
            \\hi ý
            \\h
            \\
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 9), b.contents.items.len);

        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromOffset(1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.positionFromOffset(2));
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 3 }, b.positionFromOffset(3));
        try testing.expectEqual(SP{ .offset = 4, .line = 2, .column = 4 }, b.positionFromOffset(4));
        try testing.expectEqual(SP{ .offset = 6, .line = 2, .column = 5 }, b.positionFromOffset(5)); // middle of ý
        try testing.expectEqual(SP{ .offset = 6, .line = 2, .column = 5 }, b.positionFromOffset(6));
        try testing.expectEqual(SP{ .offset = 7, .line = 3, .column = 1 }, b.positionFromOffset(7));
        try testing.expectEqual(SP{ .offset = 8, .line = 3, .column = 2 }, b.positionFromOffset(8));
    }
    {
        const text = "ý";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(1));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(2));
    }
    {
        const text = "ýý";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 4), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.positionFromOffset(1));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.positionFromOffset(2));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.positionFromOffset(3));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.positionFromOffset(4));
        try testing.expectEqual(SP{ .offset = 2, .line = 1, .column = 2 }, b.positionFromOffset(5));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(1));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(1));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n1\n\n2\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromOffset(1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.positionFromOffset(2));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.positionFromOffset(3));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.positionFromOffset(4));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.positionFromOffset(5));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r\n1\r\n\r\n2\r\n", .dos);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0)); // \r
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(1)); // \n
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.positionFromOffset(2)); // 1
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.positionFromOffset(3)); // \r
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.positionFromOffset(4)); // \n
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.positionFromOffset(5)); // \r
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.positionFromOffset(6)); // \n
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.positionFromOffset(7)); // 2
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.positionFromOffset(8)); // \r
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.positionFromOffset(9)); // \n
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.positionFromOffset(10)); // past
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r1\r\r2\r", .old_mac);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromOffset(0));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromOffset(1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.positionFromOffset(2));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.positionFromOffset(3));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.positionFromOffset(4));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.positionFromOffset(5));
    }
}

test "buffer: positionFromLineAndColumn" {
    {
        const text =
            \\
            \\
            \\Hi
            \\
            \\
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromLineAndColumn(2, 1));
        try testing.expectEqual(SP{ .offset = 2, .line = 3, .column = 1 }, b.positionFromLineAndColumn(3, 1));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 2 }, b.positionFromLineAndColumn(3, 2));
        try testing.expectEqual(SP{ .offset = 4, .line = 3, .column = 3 }, b.positionFromLineAndColumn(3, 3));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 1 }, b.positionFromLineAndColumn(4, 1));
        // Get the very last offset.
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 1 }, b.positionFromLineAndColumn(999, 999));
        // Incorrect data lower than minimum, get the very first offset.
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(0, 0));
        // Line contains only a single newline, column is bigger than the line has.
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 999));
        // Line has several characters, column is bigger than the line has.
        try testing.expectEqual(SP{ .offset = 4, .line = 3, .column = 3 }, b.positionFromLineAndColumn(3, 999));
    }
    {
        const text =
            \\
            \\hi ý
            \\h
            \\
        ;
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 9), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromLineAndColumn(2, 1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.positionFromLineAndColumn(2, 2));
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 3 }, b.positionFromLineAndColumn(2, 3));
        try testing.expectEqual(SP{ .offset = 4, .line = 2, .column = 4 }, b.positionFromLineAndColumn(2, 4));
        try testing.expectEqual(SP{ .offset = 6, .line = 2, .column = 5 }, b.positionFromLineAndColumn(2, 5));
        try testing.expectEqual(SP{ .offset = 7, .line = 3, .column = 1 }, b.positionFromLineAndColumn(3, 1));
        try testing.expectEqual(SP{ .offset = 8, .line = 3, .column = 2 }, b.positionFromLineAndColumn(3, 2));
    }
    {
        const text = "ý";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 2), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 2));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(2, 1));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 2));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(2, 1));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 2));
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(2, 1));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\n1\n\n2\n", .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromLineAndColumn(2, 1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.positionFromLineAndColumn(2, 2));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.positionFromLineAndColumn(3, 1));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.positionFromLineAndColumn(4, 1));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.positionFromLineAndColumn(4, 2));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r\n1\r\n\r\n2\r\n", .dos);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 1 }, b.positionFromLineAndColumn(2, 1));
        try testing.expectEqual(SP{ .offset = 3, .line = 2, .column = 2 }, b.positionFromLineAndColumn(2, 2));
        try testing.expectEqual(SP{ .offset = 5, .line = 3, .column = 1 }, b.positionFromLineAndColumn(3, 1));
        try testing.expectEqual(SP{ .offset = 7, .line = 4, .column = 1 }, b.positionFromLineAndColumn(4, 1));
        try testing.expectEqual(SP{ .offset = 8, .line = 4, .column = 2 }, b.positionFromLineAndColumn(4, 2));
    }
    {
        var b = try Buffer.initWithText(testing.allocator, "\r1\r\r2\r", .old_mac);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 6), b.contents.items.len);
        try testing.expectEqual(SP{ .offset = 0, .line = 1, .column = 1 }, b.positionFromLineAndColumn(1, 1));
        try testing.expectEqual(SP{ .offset = 1, .line = 2, .column = 1 }, b.positionFromLineAndColumn(2, 1));
        try testing.expectEqual(SP{ .offset = 2, .line = 2, .column = 2 }, b.positionFromLineAndColumn(2, 2));
        try testing.expectEqual(SP{ .offset = 3, .line = 3, .column = 1 }, b.positionFromLineAndColumn(3, 1));
        try testing.expectEqual(SP{ .offset = 4, .line = 4, .column = 1 }, b.positionFromLineAndColumn(4, 1));
        try testing.expectEqual(SP{ .offset = 5, .line = 4, .column = 2 }, b.positionFromLineAndColumn(4, 2));
    }
}

test "buffer: insertBytes" {
    {
        const text = "ý";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectError(error.OffsetTooBig, b.insertBytes(3, "u"));
        try testing.expectError(error.MiddleOfCodepoint, b.insertBytes(1, "u"));
        try testing.expectError(error.InvalidUtf8Sequence, b.insertBytes(0, &[_]u8{0b1011_1111}));
    }
    {
        const text = "\r\n";
        var b = try Buffer.initWithText(testing.allocator, text, .dos);
        defer b.deinit();
        try testing.expectError(error.MiddleOfDosNewline, b.insertBytes(1, "u"));
    }
    {
        const text = "";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try b.insertBytes(0, "a");
        try testing.expectEqualStrings("a", b.slice());
        try b.insertBytes(0, "b");
        try testing.expectEqualStrings("ba", b.slice());
        try b.insertBytes(1, "ee");
        try testing.expectEqualStrings("beea", b.slice());
        try b.insertBytes(1, "ý");
        try testing.expectEqualStrings("býeea", b.slice());
        try b.insertBytes(1, "c");
        try testing.expectEqualStrings("bcýeea", b.slice());
    }
}

test "buffer: removeBytes" {
    {
        const text = "ý01234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try testing.expectError(error.StartIsBiggerThanEnd, b.removeBytes(2, 0));
        try testing.expectError(error.StartBiggerThanBufferLength, b.removeBytes(10, 10));
        try testing.expectError(error.EndBiggerThanBufferLength, b.removeBytes(0, 10));
        try testing.expectError(error.MiddleOfCodepointAtStart, b.removeBytes(1, 1));
        try testing.expectError(error.MiddleOfCodepointAtEnd, b.removeBytes(0, 1));
        try testing.expectError(error.MiddleOfCodepointAtStart, b.removeBytes(1, 2));
    }
    {
        const text = "\r\n";
        var b = try Buffer.initWithText(testing.allocator, text, .dos);
        defer b.deinit();
        try testing.expectError(error.MiddleOfDosNewlineAtStart, b.removeBytes(1, 1));
        try testing.expectError(error.MiddleOfDosNewlineAtEnd, b.removeBytes(0, 1));
        try b.removeBytes(0, 0);
        try testing.expectEqual(@as(usize, 0), b.byteCount());
    }
    {
        const text = "";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.contents.items.len);
        try testing.expectError(error.StartBiggerThanBufferLength, b.removeBytes(0, 0));
    }
    {
        const text = "0123456789";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try b.removeBytes(0, 0);
        try testing.expectEqualStrings("123456789", b.slice());
    }
    {
        const text = "0123456789";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try b.removeBytes(1, 1);
        try testing.expectEqualStrings("023456789", b.slice());
    }
    {
        const text = "0123456789";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(0, 9);
        try testing.expectEqualStrings("", b.slice());
    }
    {
        const text = "0123456789";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(0, 5);
        try testing.expectEqualStrings("6789", b.slice());
    }
    {
        const text = "0123456789";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(5, 9);
        try testing.expectEqualStrings("01234", b.slice());
    }
    {
        const text = "0123456789";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(2, 7);
        try testing.expectEqualStrings("0189", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(0, 3);
        try testing.expectEqualStrings("234567", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(0, 1);
        try testing.expectEqualStrings("1234567", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(0, 0);
        try testing.expectEqualStrings("ý1234567", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(1, 1);
        try testing.expectEqualStrings("01234567", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(1, 3);
        try testing.expectEqualStrings("0234567", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(3, 3);
        try testing.expectEqualStrings("0ý234567", b.slice());
    }
    {
        const text = "0ý1234567";
        var b = try Buffer.initWithText(testing.allocator, text, .unix);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 10), b.contents.items.len);
        try b.removeBytes(3, 4);
        try testing.expectEqualStrings("0ý34567", b.slice());
    }
}
