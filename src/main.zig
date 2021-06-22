const std = @import("std");

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ally = &arena.allocator;

    var arg_it = std.process.args();
    _ = try arg_it.next(ally) orelse unreachable; // program name
    const file_name = arg_it.next(ally);
    // We accept both files and standard input.
    var file_handle = blk: {
        if (file_name) |file_name_delimited| {
            const fname: []const u8 = try file_name_delimited;
            break :blk try std.fs.cwd().openFile(fname, .{});
        } else {
            break :blk std.io.getStdIn();
        }
    };
    defer file_handle.close();
    const content = try file_handle.readToEndAlloc(ally, std.math.maxInt(usize));

    std.debug.print("{s}", .{content});
}
