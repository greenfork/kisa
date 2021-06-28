const std = @import("std");
const os = std.os;
const io = std.io;

pub const MoveDirection = enum {
    up,
    down,
    left,
    right,
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

    pub inline fn next_key(self: *Self) ?Keys.Key {
        return self.backend.next_key();
    }

    pub inline fn moveCursor(self: *Self, direction: MoveDirection, number: u32) !void {
        try self.backend.moveCursor2(direction, number);
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
    insert_character: u8,
};

pub const Event = struct {
    value: EventValue,
};

var current_mode_is_insert = true;

/// An interface for processing all the events. Events can be of any kind, such as modifying the
/// `TextBuffer` or just changing the cursor position on the screen. Events can spawn more events
/// and are processed sequentially. This should also allow us to add so called "hooks" which are
/// actions that will be executed only when a specific event is fired, they will be useful as
/// an extension point for user-defined hooks.
pub const EventDispatcher = struct {
    text_buffer: *TextBuffer,

    pub const Error = TextBuffer.Error || DisplayWindow.Error;
    const Self = @This();

    pub fn init(text_buffer: *TextBuffer) Self {
        return .{ .text_buffer = text_buffer };
    }

    pub fn dispatch(self: Self, event: Event) Error!void {
        switch (event.value) {
            .key_press => |val| {
                if (val.utf8len() > 1) {
                    std.debug.print("Character sequence longer than 1 byte: {s}\n", .{val.utf8});
                    std.os.exit(1);
                }
                if (current_mode_is_insert) {
                    try self.dispatch(.{ .value = .{ .insert_character = val.utf8[0] } });
                } else {
                    switch (val.utf8[0]) {
                        'k' => {
                            try self.text_buffer.display_windows[0].ui.moveCursor(.up, 1);
                        },
                        else => {
                            std.debug.print("Unknown command: {c}\n", .{val.utf8[0]});
                            std.os.exit(1);
                        },
                    }
                }
            },
            .insert_character => |val| {
                try self.text_buffer.insert(100, val);
                try self.text_buffer.display_windows[0].render();
            },
            else => {
                std.debug.print("Not supported event: {}\n", .{event});
                std.os.exit(1);
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

/// Manages the data of what the user sees on the screen. Sends all the necessary data
/// to UI to display it on the screen.
pub const DisplayWindow = struct {
    rows: u32,
    cols: u32,
    cursor: Cursor,
    text_buffer: *TextBuffer,
    ui: UI,
    first_line_number: u32,

    const Self = @This();
    const Error = UI.Error || TextBuffer.Error;

    pub fn init(text_buffer: *TextBuffer, ui: UI) Self {
        return Self{
            .rows = ui.textAreaRows(),
            .cols = ui.textAreaCols(),
            .cursor = Cursor{ .line = 1, .col = 1, .x = 0, .y = 0 },
            .text_buffer = text_buffer,
            .ui = ui,
            .first_line_number = 1,
        };
    }

    pub fn render(self: *Self) Error!void {
        const last_line_number = self.first_line_number + self.rows;
        const slice = try self.text_buffer.toLineSlice(self.first_line_number, last_line_number);
        try self.ui.render(slice, self.first_line_number, self.text_buffer.max_line_number);
    }
};

/// Manages the actual text of an opened file and provides an interface for querying it and
/// modifying.
pub const TextBuffer = struct {
    ally: *std.mem.Allocator,
    content: Content,
    // TODO: make it usable, for now we just use a single element
    display_windows: [1]*DisplayWindow = undefined,
    // metrics
    max_line_number: u32,

    pub const Error = error{ OutOfMemory, LineOutOfRange };
    const Self = @This();
    const Content = std.ArrayList(u8);

    pub fn init(ally: *std.mem.Allocator, content: []const u8) Error!Self {
        const duplicated_content = try ally.dupe(u8, content);
        const our_content = Content.fromOwnedSlice(ally, duplicated_content);
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

    const content = readInput(ally) catch |err| switch (err) {
        error.FileNotSupplied => {
            std.debug.print("No file supplied\n{s}", .{help_string});
            std.os.exit(1);
        },
        else => return err,
    };

    var text_buffer = try TextBuffer.init(ally, content);
    var uivt100 = try UIVT100.init();
    defer uivt100.deinit() catch {
        std.debug.print("UIVT100 deinit ERRROR", .{});
        std.os.exit(1);
    };
    var ui = UI.init(uivt100);
    var display_window = DisplayWindow.init(&text_buffer, ui);
    // FIXME: not keep window on the stack
    text_buffer.display_windows[0] = &display_window;
    var event_dispatcher = EventDispatcher.init(&text_buffer);

    try display_window.render();

    while (true) {
        if (ui.next_key()) |key| {
            switch (key.code) {
                .unicode_codepoint => {
                    if (key.is_ctrl('c')) {
                        break;
                    } else {
                        try event_dispatcher.dispatch(.{ .value = .{ .key_press = key } });
                    }
                },
                else => {
                    std.debug.print("Unrecognized key event: {}\r\n", .{key});
                    std.os.exit(1);
                },
            }
        }

        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

pub const Keys = struct {
    pub const KeySym = enum {
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,
    };

    pub const MouseButton = enum {
        left,
        middle,
        right,
        scroll_up,
        scroll_down,
    };

    pub const KeyKind = enum {
        unrecognized,
        unicode_codepoint,
        function,
        keysym,
        mouse_button,
        mouse_position,
    };

    pub const KeyCode = union(KeyKind) {
        unrecognized: void,
        unicode_codepoint: u32,
        function: u8,
        keysym: KeySym,
        mouse_button: MouseButton,
        mouse_position: struct { x: u32, y: u32 },
    };

    pub const Key = struct {
        code: KeyCode,
        modifiers: u8 = 0,
        // Any Unicode character can be UTF-8 encoded in no more than 6 bytes, plus terminating null
        utf8: [7]u8 = undefined,

        // zig fmt: off
        const shift_bit     = @as(u8, 1 << 0);
        const alt_bit       = @as(u8, 1 << 1);
        const ctrl_bit      = @as(u8, 1 << 2);
        const super_bit     = @as(u8, 1 << 3);
        const hyper_bit     = @as(u8, 1 << 4);
        const meta_bit      = @as(u8, 1 << 5);
        const caps_lock_bit = @as(u8, 1 << 6);
        const num_lock_bit  = @as(u8, 1 << 7);
        // zig fmt: on

        pub fn has_shift(self: Key) bool {
            return (self.modifiers & shift_bit) != 0;
        }
        pub fn has_alt(self: Key) bool {
            return (self.modifiers & alt_bit) != 0;
        }
        pub fn has_ctrl(self: Key) bool {
            return (self.modifiers & ctrl_bit) != 0;
        }
        pub fn has_super(self: Key) bool {
            return (self.modifiers & super_bit) != 0;
        }
        pub fn has_hyper(self: Key) bool {
            return (self.modifiers & hyper_bit) != 0;
        }
        pub fn has_meta(self: Key) bool {
            return (self.modifiers & meta_bit) != 0;
        }
        pub fn has_caps_lock(self: Key) bool {
            return (self.modifiers & caps_lock_bit) != 0;
        }
        pub fn has_num_lock(self: Key) bool {
            return (self.modifiers & num_lock_bit) != 0;
        }

        // TODO: change scope to private
        pub fn utf8len(self: Key) usize {
            var length: usize = 0;
            for (self.utf8) |byte| {
                if (byte == 0) break;
                length += 1;
            } else {
                unreachable; // we are responsible for making sure this never happens
            }
            return length;
        }
        pub fn is_ascii(self: Key) bool {
            return self.code == .unicode_codepoint and self.utf8len() == 1;
        }
        pub fn is_ctrl(self: Key, character: u8) bool {
            return self.is_ascii() and self.utf8[0] == character and self.modifiers == ctrl_bit;
        }

        pub fn ascii(character: u8) Key {
            var key = Key{ .code = .{ .unicode_codepoint = character } };
            key.utf8[0] = character;
            key.utf8[1] = 0;
            return key;
        }
        pub fn ctrl(character: u8) Key {
            var key = ascii(character);
            key.modifiers = ctrl_bit;
            return key;
        }
    };
};

test "keys" {
    try std.testing.expect(!Keys.Key.ascii('c').has_ctrl());
    try std.testing.expect(Keys.Key.ctrl('c').has_ctrl());
    try std.testing.expect(Keys.Key.ascii('c').is_ascii());
    try std.testing.expect(Keys.Key.ctrl('c').is_ascii());
    try std.testing.expect(Keys.Key.ctrl('c').is_ctrl('c'));
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
        // Polling read, doesn't block
        raw_termios.cc[os.VMIN] = 0;
        raw_termios.cc[os.VTIME] = 0;
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

    fn next_byte(self: *Self) ?u8 {
        return self.in_stream.reader().readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            error.NotOpenForReading => return null,
            else => {
                std.debug.print("Unexpected error: {}\r\n", .{err});
                return 0;
            },
        };
    }

    pub fn next_key(self: *Self) ?Keys.Key {
        if (self.next_byte()) |byte| {
            if (byte == 3) {
                return Keys.Key.ctrl('c');
            }
            return Keys.Key.ascii(byte);
        } else {
            return null;
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

    pub fn moveCursor2(self: *Self, direction: MoveDirection, number: u32) !void {
        switch (direction) {
            .up => {
                try self.moveCursorUp(number);
            },
            else => {},
        }
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
    fn moveCursorUp(self: *Self, number: u32) !void {
        try self.raw_writer().print("{s}[{d}A", .{ csi, number });
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
