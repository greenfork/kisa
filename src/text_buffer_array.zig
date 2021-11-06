//! Contiguous array implementation of a text buffer. The most naive and ineffective implementation,
//! it is supposed to be an experiement to identify the correct API and common patterns.
const std = @import("std");
const os = std.os;
const mem = std.mem;
const kisa = @import("kisa");
const assert = std.debug.assert;
const testing = std.testing;
const Zigstr = @import("zigstr");

pub const Contents = Zigstr;

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
};

test "state2: init text buffer with file descriptor" {
    var file = try std.fs.cwd().openFile("kisarc.zzz", .{});
    defer file.close();
    var text_buffer = try initContentsWithFile(
        testing.allocator,
        file,
    );
    defer text_buffer.deinit(testing.allocator);
}

test "state2: init text buffer with text" {
    var text_buffer = try initContentsWithText(
        testing.allocator,
        "Hello",
    );
    defer text_buffer.deinit(testing.allocator);
}
