//! Contiguous array implementation of a text buffer. The most naive and ineffective implementation,
//! it is supposed to be an experiement to identify the correct API and common patterns.
const std = @import("std");
const os = std.os;
const mem = std.mem;
const kisa = @import("kisa");
const assert = std.debug.assert;

pub const Contents = std.ArrayList(u8);

pub fn Behavior(comptime Self: type) type {
    return struct {
        pub fn initContentsWithFile(ally: *mem.Allocator, file: std.fs.File) !Contents {
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
            return Contents.fromOwnedSlice(ally, contents);
        }

        pub fn initContentsWithText(ally: *mem.Allocator, text: []const u8) !Contents {
            const contents = try ally.dupe(u8, text);
            return Contents.fromOwnedSlice(ally, contents);
        }

        pub fn deinitContents(self: Self) void {
            self.contents.deinit();
        }

        pub fn detectFeaturesAndMetrics(self: *Self) void {
            self.metrics.max_line_number += 1;
        }

        pub fn cursorMoveLeft(self: *Self, selections: *kisa.Selections) void {
            _ = self;
            for (selections.items) |*selection| {
                if (selection.cursor != 0) {
                    selection.cursor -= 1;
                    if (!selection.anchored and selection.anchor != 0) {
                        selection.anchor -= 1;
                    }
                }
            }
        }
    };
}
