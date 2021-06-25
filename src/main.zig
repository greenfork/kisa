const std = @import("std");
const os = std.os;
const io = std.io;
const ncurses = @import("ncurses").ncurses;

pub const Key = struct {
    value: u32,
};

/// A high-level abstraction which accepts a backend and provides a set of functions to operate on
/// the backend. Backend itself contains all low-level functions which might not be all useful
/// in a high-level interaction context.
pub const UI = struct {
    backend: UIVT100,

    pub const Error = UIVT100.Error;
    const Self = @This();

    pub fn init(backend: UIVT100) Self {
        return .{ .backend = backend };
    }
};

/// An interface for processing all the events. Events can be of any kind, such as modifying the
/// `Buffer` or just changing the cursor position on the screen. Events can spawn more events
/// and are processed sequentially. This should also allow us to add so called "hooks" which are
/// actions that will be executed only when a specific event is fired, they will be useful as
/// an extension point for user-defined hooks.
pub const EventDispatcher = struct {
    ui: UI,

    pub const Error = @TypeOf(ui).Error;
    const Self = @This();

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

    pub fn init(ui: UI) Self {
        return .{ .ui = ui };
    }

    pub fn dispatch(self: Self, event: Event) EventDispatcherError!void {
        switch (event.value) {
            .key_press => |val| {
                try self.dispatch(.{ .value = .{ .insert_character = val } });
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

/// Manages the actual text of an opened file and provides an interface for querying it and
/// modifying.
pub const Buffer = struct {
    ally: *std.mem.Allocator,
    content: []u8,
    line_it: std.mem.SplitIterator,

    pub const Error = error{OutOfMemory};
    const Self = @This();

    pub fn init(ally: *std.mem.Allocator, content: []const u8) Error!Self {
        return .{
            .ally = ally,
            .content = try ally.dupe(u8, content),
            .line_it = std.mem.split(content, "\n"),
        };
    }

    pub fn next_line(self: *Self) ?[]const u8 {
        return self.line_it.next();
    }

    pub fn line_reset(self: *Self) void {
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
    var line_count: u32 = @intCast(u32, std.mem.count(u8, content, "\n"));
    const max_line_count_width = numberWidth(line_count);
    buffer.line_reset();

    var ui = try UIVT100.init();
    defer ui.deinit() catch {
        std.debug.print("UIVT100 deinit ERRROR", .{});
    };

    line_count = 1;
    while (buffer.next_line()) |line| : (line_count += 1) {
        if (line_count == 24) break;
        {
            var i = max_line_count_width - numberWidth(line_count);
            try ui.writer().writeByteNTimes(' ', i);
        }
        try ui.writer().print("{d} {s}\n", .{ line_count, line });
    }
    try ui.refresh();

    // // ncurses edit
    // const ch_c = try getch();
    // const ch = @intCast(u32, ch_c);
    // try event_dispatcher.dispatch(
    //     EventDispatcher.Event{
    //         .value = EventDispatcher.EventValue{ .key_press = Key{ .value = ch } },
    //     },
    // );

    // // _ = try getch();

    // std.time.sleep(1 * std.time.ns_per_s);
}

/// UI backend. VT100 is an old hardware terminal from 1978. Although it lacks a lot of capabilities
/// which are exposed in this implementation, such as colored output, it established a standard
/// of ASCII escape sequences which is implemented in most terminal emulators as of today.
/// Later this standard was extended and this implementation is a common denominator that is
/// likely to be supported in most terminal emulators.
pub const UIVT100 = struct {
    in_stream: std.fs.File,
    out_stream: std.fs.File,
    original_termois: ?os.termios,
    buffered_writer_ctx: RawBufferedWriterCtx,

    pub const Error = error{NotTTY} || os.TermiosSetError || std.fs.File.WriteError;
    const Self = @This();

    const write_buffer_size = 4096;
    /// Control Sequence Introducer, see console_codes(4)
    const csi = "\x1b[";

    pub fn init() Error!Self {
        const in_stream = io.getStdIn();
        const out_stream = io.getStdOut();
        if (!os.isatty(in_stream.handle)) return Error.NotTTY;
        var uivt100 = UIVT100{
            .in_stream = in_stream,
            .out_stream = out_stream,
            .original_termois = try os.tcgetattr(in_stream.handle),
            .buffered_writer_ctx = RawBufferedWriterCtx{ .unbuffered_writer = out_stream.writer() },
        };
        errdefer uivt100.deinit() catch {
            std.debug.print("UIVT100 deinit ERRROR", .{});
        };

        // Black magic
        var raw_termios = uivt100.original_termois.?;
        raw_termios.iflag &=
            ~(@as(os.tcflag_t, os.BRKINT) | os.ICRNL | os.INPCK | os.ISTRIP | os.IXON);
        raw_termios.oflag &= ~(@as(os.tcflag_t, os.OPOST));
        raw_termios.cflag |= os.CS8;
        raw_termios.lflag &= ~(@as(os.tcflag_t, os.ECHO) | os.ICANON | os.IEXTEN | os.ISIG);
        raw_termios.cc[os.VMIN] = 0;
        raw_termios.cc[os.VTIME] = 1;
        try os.tcsetattr(in_stream.handle, os.TCSA.FLUSH, raw_termios);

        // Prepare terminal
        try uivt100.clear();

        return uivt100;
    }

    pub fn deinit(self: *Self) Error!void {
        if (self.original_termois) |termios| {
            try os.tcsetattr(self.in_stream.handle, os.TCSA.FLUSH, termios);
            self.original_termois = null;
        }
    }

    // Do type magic to expose buffered writer in 2 modes:
    // * raw_writer - we don't try to do anything smart, mostly for control codes
    // * writer - we try to do what is expected when writing to a screen
    const RawUnbufferedWriter = io.Writer(std.fs.File, std.fs.File.WriteError, std.fs.File.write);
    const RawBufferedWriterCtx = io.BufferedWriter(write_buffer_size, RawUnbufferedWriter);
    pub const RawBufferedWriter = RawBufferedWriterCtx.Writer;
    pub const BufferedWriter = io.Writer(*UIVT100, RawBufferedWriterCtx.Error, writerfn);

    fn raw_writer(self: *Self) RawBufferedWriter {
        return self.buffered_writer_ctx.writer();
    }

    pub fn writer(self: *Self) BufferedWriter {
        return .{ .context = self };
    }

    fn writerfn(self: *Self, string: []const u8) !usize {
        for (string) |ch| {
            if (ch == '\n') try self.raw_writer().writeByte('\r');
            try self.raw_writer().writeByte(ch);
        }
        return string.len;
    }

    pub fn clear(self: *Self) !void {
        try self.eraseDisplay();
        try self.moveCursor(1, 1);
        try self.refresh();
    }

    pub fn refresh(self: *Self) !void {
        try self.buffered_writer_ctx.flush();
    }

    fn eraseDisplay(self: *Self) !void {
        try self.raw_writer().writeAll(csi ++ "2J");
    }
    fn moveCursor(self: *Self, row: u32, col: u32) !void {
        try self.raw_writer().print("{s}{d};{d}H", .{ csi, row, col });
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
