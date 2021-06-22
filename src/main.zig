const std = @import("std");
usingnamespace @import("ncurses").ncurses;

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ally = &arena.allocator;

    const content = try readInput(ally);

    _ = try initscr();
    defer endwin() catch {};
    try printwzig("{s}", .{content});
    try refresh();
    _ = try getch();
}

fn readInput(ally: *std.mem.Allocator) ![]u8 {
    var arg_it = std.process.args();
    _ = try arg_it.next(ally) orelse unreachable; // program name
    const file_name = arg_it.next(ally);
    // We accept both files and standard input.
    var file_handle = blk: {
        if (file_name) |file_name_delimited| {
            const fname: []const u8 = try file_name_delimited;
            break :blk try std.fs.cwd().openFile(fname, .{});
        } else {
            // FIXME: stdin blocks ncurses
            break :blk std.io.getStdIn();
        }
    };
    defer file_handle.close();
    return try file_handle.readToEndAlloc(ally, std.math.maxInt(usize));
}
