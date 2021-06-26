const std = @import("std");
const os = std.os;
const io = std.io;

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

    pub fn render(self: *Self, string: []const u8, first_line_number: u32, max_line_number: u32) !void {
        try self.backend.clear();
        var w = self.backend.writer();
        var line_count = first_line_number;
        const max_line_number_width = numberWidth(max_line_number);
        var line_it = std.mem.split(string, "\n");
        while (line_it.next()) |line| : (line_count += 1) {
            // When there's a trailing newline, we don't display the very last row.
            if (line_count == max_line_number and line.len == 0) break;

            try w.writeByteNTimes(' ', max_line_number_width - numberWidth(line_count));
            try w.print("{d} {s}\n", .{ line_count, line });
        }
        try self.backend.refresh();
    }

    pub inline fn textAreaRows(self: Self) u32 {
        return self.backend.textAreaRows();
    }

    pub inline fn textAreaCols(self: Self) u32 {
        return self.backend.textAreaCols();
    }
};

pub const EventKind = enum {
    none,
    key_press,
    insert_character,
};

pub const EventValue = union(EventKind) {
    none: void,
    key_press: Keys.Key,
    insert_character: Keys.Key,
};

pub const Event = struct {
    value: EventValue,
};

/// An interface for processing all the events. Events can be of any kind, such as modifying the
/// `Buffer` or just changing the cursor position on the screen. Events can spawn more events
/// and are processed sequentially. This should also allow us to add so called "hooks" which are
/// actions that will be executed only when a specific event is fired, they will be useful as
/// an extension point for user-defined hooks.
pub const EventDispatcher = struct {
    buffer: *Buffer,

    pub const Error = Buffer.Error || Window.Error;
    const Self = @This();

    pub fn init(buffer: *Buffer) Self {
        return .{ .buffer = buffer };
    }

    pub fn dispatch(self: Self, event: Event) Error!void {
        switch (event.value) {
            .key_press => |val| {
                try self.dispatch(.{ .value = .{ .insert_character = val } });
            },
            .insert_character => |val| {
                try self.buffer.insert(100, val.value);
                try self.buffer.windows[0].render();
            },
            else => {
                std.debug.print("Not supported event: {}\n", .{event});
            },
        }
    }
};

pub const Cursor = struct {
    line: u32,
    col: u32,
    x: u32,
    y: u32,
};

/// Manages the representation of what the user sees on the screen. Also contains parts of UI
/// state such as cursor position.
pub const Window = struct {
    rows: u32,
    cols: u32,
    cursor: Cursor,
    buffer: *Buffer,
    ui: UI,
    first_line_number: u32,

    const Self = @This();
    const Error = UI.Error || Buffer.Error;

    pub fn init(buffer: *Buffer, ui: UI) Self {
        return Self{
            .rows = ui.textAreaRows(),
            .cols = ui.textAreaCols(),
            .cursor = Cursor{ .line = 1, .col = 1, .x = 0, .y = 0 },
            .buffer = buffer,
            .ui = ui,
            .first_line_number = 1,
        };
    }

    pub fn render(self: *Self) Error!void {
        const last_line_number = self.first_line_number + self.rows;
        const slice = try self.buffer.toLineSlice(self.first_line_number, last_line_number);
        try self.ui.render(slice, self.first_line_number, self.buffer.max_line_number);
    }
};

/// Manages the actual text of an opened file and provides an interface for querying it and
/// modifying.
pub const Buffer = struct {
    ally: *std.mem.Allocator,
    content: ContentType,
    // TODO: make it usable, for now we just use a single element
    windows: [1]*Window = undefined,
    // metrics
    max_line_number: u32,

    pub const Error = error{ OutOfMemory, LineOutOfRange };
    const Self = @This();
    const ContentType = std.ArrayList(u8);

    pub fn init(ally: *std.mem.Allocator, content: []const u8) Error!Self {
        const duplicated_content = try ally.dupe(u8, content);
        const our_content = ContentType.fromOwnedSlice(ally, duplicated_content);
        var result = Self{
            .ally = ally,
            .content = our_content,
            .max_line_number = undefined,
        };
        result.countMetrics();
        return result;
    }

    fn countMetrics(self: *Self) void {
        self.max_line_number = 1;
        for (self.content.items) |ch| {
            if (ch == '\n') self.max_line_number += 1;
        }
    }

    pub fn toLineSlice(self: Self, first_line_number: u32, last_line_number: u32) ![]const u8 {
        var line_number: u32 = 1;
        var start_offset: usize = std.math.maxInt(usize);
        var end_offset: usize = std.math.maxInt(usize);
        const slice = self.content.items;
        for (slice) |ch, idx| {
            if (start_offset == std.math.maxInt(usize) and first_line_number == line_number) {
                start_offset = idx;
            }
            if (end_offset == std.math.maxInt(usize) and last_line_number == line_number) {
                end_offset = idx;
                break;
            }
            if (ch == '\n') line_number += 1;
        } else {
            // Screen height is more than we have text available
            end_offset = slice.len;
        }
        if (start_offset == std.math.maxInt(usize) or end_offset == std.math.maxInt(usize)) {
            std.debug.print(
                "first_line: {d}, last_line: {d}, line_num: {d}, start: {d}, end: {d}\n",
                .{ first_line_number, last_line_number, line_number, start_offset, end_offset },
            );
            return Error.LineOutOfRange;
        }
        return slice[start_offset..end_offset];
    }

    pub fn append(self: *Self, character: u8) !void {
        try self.content.append(character);
        self.countMetrics();
    }

    pub fn insert(self: *Self, index: usize, character: u8) !void {
        try self.content.insert(index, character);
        self.countMetrics();
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
    var uivt100 = try UIVT100.init();
    defer uivt100.deinit() catch {
        std.debug.print("UIVT100 deinit ERRROR", .{});
    };
    var ui = UI.init(uivt100);
    var window = Window.init(&buffer, ui);
    // FIXME: not keep window on the stack
    buffer.windows[0] = &window;
    var event_dispatcher = EventDispatcher.init(&buffer);

    try window.render();

    while (true) {
        if (Keys.next(uivt100.in_stream)) |key| {
            switch (key.value) {
                Keys.ctrl('c') => break,
                else => try event_dispatcher.dispatch(Event{ .value = .{ .key_press = key } }),
            }
        }

        std.time.sleep(5 * std.time.ns_per_ms);
    }
}

pub const Keys = struct {
    pub const Key = struct {
        value: u8,
    };

    pub fn next(stream: std.fs.File) ?Key {
        const character: u8 = stream.reader().readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => unreachable,
        };
        return Key{ .value = character };
    }

    pub fn ctrl(character: u8) u8 {
        std.debug.assert('a' <= character and character <= 'z');
        return character - 0x60;
    }
};

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
    rows: u32,
    cols: u32,

    pub const Error = error{
        NotTTY,
        NoAnsiEscapeSequences,
        NoWindowSize,
    } || os.TermiosSetError || std.fs.File.WriteError;

    const Self = @This();

    const write_buffer_size = 4096;
    /// Control Sequence Introducer, see console_codes(4)
    const csi = "\x1b[";
    const status_line_width = 1;

    pub fn init() Error!Self {
        const in_stream = io.getStdIn();
        const out_stream = io.getStdOut();
        if (!in_stream.isTty()) return Error.NotTTY;
        if (!out_stream.supportsAnsiEscapeCodes()) return Error.NoAnsiEscapeSequences;
        var uivt100 = UIVT100{
            .in_stream = in_stream,
            .out_stream = out_stream,
            .original_termois = try os.tcgetattr(in_stream.handle),
            .buffered_writer_ctx = RawBufferedWriterCtx{ .unbuffered_writer = out_stream.writer() },
            .rows = undefined,
            .cols = undefined,
        };
        errdefer uivt100.deinit() catch {
            std.debug.print("UIVT100 deinit ERRROR", .{});
        };
        try uivt100.updateWindowSize();

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

    pub fn textAreaRows(self: Self) u32 {
        return self.rows - status_line_width;
    }

    pub fn textAreaCols(self: Self) u32 {
        return self.cols;
    }

    fn getWindowSize(self: Self, rows: *u32, cols: *u32) !void {
        while (true) {
            var window_size: os.linux.winsize = undefined;
            const fd = @bitCast(usize, @as(isize, self.in_stream.handle));
            switch (os.linux.syscall3(.ioctl, fd, os.linux.TIOCGWINSZ, @ptrToInt(&window_size))) {
                0 => {
                    rows.* = window_size.ws_row;
                    cols.* = window_size.ws_col;
                    return;
                },
                os.EINTR => continue,
                else => return Error.NoWindowSize,
            }
        }
    }

    fn updateWindowSize(self: *Self) !void {
        var rows: u32 = undefined;
        var cols: u32 = undefined;
        try self.getWindowSize(&rows, &cols);
        self.rows = rows;
        self.cols = cols;
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
