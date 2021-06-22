const std = @import("std");
usingnamespace @import("ncurses").ncurses;

const max_height = 24;

pub const BufferError = error{OutOfMemory};

pub const Buffer = struct {
    ally: *std.mem.Allocator,
    content: []u8,
    line_it: std.mem.SplitIterator,

    pub fn init(ally: *std.mem.Allocator, content: []const u8) BufferError!Buffer {
        return Buffer{
            .ally = ally,
            .content = try ally.dupe(u8, content),
            .line_it = std.mem.split(content, "\n"),
        };
    }

    pub fn next_line(self: *Buffer) ?[]const u8 {
        return self.line_it.next();
    }

    pub fn line_reset(self: *Buffer) void {
        self.line_it.index = 0;
    }
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ally = &arena.allocator;

    const content = try readInput(ally);
    var buffer = try Buffer.init(ally, content);

    _ = try initscr();
    defer endwin() catch {};

    var line_count: u32 = 1;
    while (buffer.next_line()) |line| : (line_count += 1) {
        if (line_count == max_height) break;
    }
    const max_line_count_width = numberWidth(line_count);
    buffer.line_reset();

    line_count = 1;
    while (buffer.next_line()) |line| : (line_count += 1) {
        if (line_count == 24) break;
        {
            var i = max_line_count_width - numberWidth(line_count);
            while (i != 0) : (i -= 1) {
                try addch(' ');
            }
        }
        try printwzig("{d} {s}\n", .{ line_count, line });
    }
    try refresh();
    _ = try getch();
}

fn numberWidth(number: u32) u32 {
    var result: u32 = 0;
    var n = number;
    while (n != 0) : (n /= 10) {
        result += 1;
    }
    return result;
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
