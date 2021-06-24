const std = @import("std");
const os = std.os;
const io = std.io;
const ncurses = @import("ncurses").ncurses;
// usingnamespace ncurses;

const max_height = 24;

pub const Key = struct {
    value: u32,
};

pub const UIError = ncurses.NcursesError;

pub const UI = struct {
    window: Window,

    pub fn init(window: Window) UI {
        return UI{ .window = window };
    }

    pub fn insertCharacter(self: UI, ch: u32) !void {
        try self.window.waddch(ch);
        try refresh();
    }
};

pub const EventDispatcherError = UIError;

pub const EventDispatcher = struct {
    ui: UI,

    pub const EventKind = enum {
        none,
        key_press,
        insert_character,
    };

    pub const EventValue = union(EventKind) {
        none: void,
        key_press: Key,
        insert_character: Key,
    };

    pub const Event = struct {
        value: EventValue,
    };

    pub fn init(ui: UI) EventDispatcher {
        return EventDispatcher{ .ui = ui };
    }

    pub fn dispatch(self: EventDispatcher, event: Event) EventDispatcherError!void {
        switch (event.value) {
            .key_press => |val| {
                try self.dispatch(Event{
                    .value = .{ .insert_character = val },
                });
            },
            .insert_character => |val| {
                try self.ui.insertCharacter(val.value);
            },
            else => {
                std.debug.print("Not supported event: {}\n", .{event});
            },
        }
    }
};

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

    // Initialize buffer
    const content = readInput(ally) catch |err| switch (err) {
        error.FileNotSupplied => {
            std.debug.print("No file supplied\n{s}", .{help_string});
            std.os.exit(1);
        },
        else => return err,
    };
    var buffer = try Buffer.init(ally, content);
    var line_count: u32 = 1;
    while (buffer.next_line()) |line| : (line_count += 1) {
        if (line_count == max_height) break;
    }
    const max_line_count_width = numberWidth(line_count);
    buffer.line_reset();

    var ui = try UIVT100.init();
    defer ui.deinit() catch {
        std.debug.print("UIVT100 deinit ERRROR", .{});
    };

    line_count = 1;
    while (buffer.next_line()) |line| : (line_count += 1) {
        if (line_count == max_height) break;
        {
            var i = max_line_count_width - numberWidth(line_count);
            try ui.writer().writeByteNTimes(' ', i);
        }
        try ui.writer().print("{d} {s}\n", .{ line_count, line });
    }
    // try refresh();

    // // ncurses edit
    // const ch_c = try getch();
    // const ch = @intCast(u32, ch_c);
    // try event_dispatcher.dispatch(
    //     EventDispatcher.Event{
    //         .value = EventDispatcher.EventValue{ .key_press = Key{ .value = ch } },
    //     },
    // );

    // // _ = try getch();

    std.time.sleep(1 * std.time.ns_per_s);
}

pub const UIVT100Error = error{NotTTY} || os.TermiosSetError || std.fs.File.WriteError;

pub const UIVT100 = struct {
    in_stream: std.fs.File,
    out_stream: std.fs.File,
    original_termois: ?os.termios,

    pub fn init() UIVT100Error!UIVT100 {
        const in_stream = io.getStdIn();
        const out_stream = io.getStdOut();
        if (!os.isatty(in_stream.handle)) return UIVT100Error.NotTTY;

        var result = UIVT100{
            .in_stream = in_stream,
            .out_stream = out_stream,
            .original_termois = try os.tcgetattr(in_stream.handle),
        };
        errdefer result.deinit() catch {
            std.debug.print("UIVT100 deinit ERRROR", .{});
        };

        var raw_termios = result.original_termois.?;
        raw_termios.iflag &=
            ~(@as(os.tcflag_t, os.BRKINT) | os.ICRNL | os.INPCK | os.ISTRIP | os.IXON);
        raw_termios.oflag &= ~(@as(os.tcflag_t, os.OPOST));
        raw_termios.cflag |= os.CS8;
        raw_termios.lflag &= ~(@as(os.tcflag_t, os.ECHO) | os.ICANON | os.IEXTEN | os.ISIG);
        raw_termios.cc[os.VMIN] = 0;
        raw_termios.cc[os.VTIME] = 1;
        try os.tcsetattr(in_stream.handle, os.TCSA.FLUSH, raw_termios);
        try result.clear();
        return result;
    }

    pub fn deinit(self: *UIVT100) UIVT100Error!void {
        if (self.original_termois) |termios| {
            try os.tcsetattr(self.in_stream.handle, os.TCSA.FLUSH, termios);
            self.original_termois = null;
        }
    }

    pub fn raw_writer(self: UIVT100) std.fs.File.Writer {
        return self.out_stream.writer();
    }

    pub const Writer = std.io.Writer(*UIVT100, std.fs.File.WriteError, writerfn);

    pub fn writer(self: *UIVT100) Writer {
        return .{ .context = self };
    }

    fn writerfn(self: *UIVT100, string: []const u8) !usize {
        for (string) |ch| {
            try self.raw_writer().writeByte(ch);
            if (ch == '\n') try self.raw_writer().writeByte('\r');
        }
        return string.len;
    }

    fn clear(self: *UIVT100) !void {
        try self.raw_writer().print("{c}[H", .{std.ascii.control_code.ESC});
        try self.raw_writer().print("{c}[2J", .{std.ascii.control_code.ESC});
    }
};

const help_string =
    \\Usage: kisa file
    \\
;

fn numberWidth(number: u32) u32 {
    var result: u32 = 0;
    var n = number;
    while (n != 0) : (n /= 10) {
        result += 1;
    }
    return result;
}

// TODO: support input from stdin
fn readInput(ally: *std.mem.Allocator) ![]u8 {
    var arg_it = std.process.args();
    _ = try arg_it.next(ally) orelse unreachable; // program name
    var file = blk: {
        if (arg_it.next(ally)) |file_name_delimited| {
            const file_name: []const u8 = try file_name_delimited;
            break :blk try std.fs.cwd().openFile(file_name, .{});
        } else {
            return error.FileNotSupplied;
        }
    };
    defer file.close();
    return try file.readToEndAlloc(ally, std.math.maxInt(usize));
}
