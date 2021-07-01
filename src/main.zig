const std = @import("std");
const os = std.os;
const io = std.io;

pub const MoveDirection = enum {
    up,
    down,
    left,
    right,
};

/// A high-level abstraction which accepts a frontend and provides a set of functions to operate on
/// the frontent. Frontend itself contains all low-level functions which might not be all useful
/// in a high-level interaction context.
pub const UI = struct {
    frontend: UIVT100,

    pub const Error = UIVT100.Error;
    const Self = @This();

    pub fn init(frontend: UIVT100) Self {
        return .{ .frontend = frontend };
    }

    // TODO: rewrite this to not use "cc" functions
    pub fn draw(self: *Self, string: []const u8, first_line_number: u32, max_line_number: u32) !void {
        try self.frontend.ccHideCursor();
        try self.frontend.clear();
        var w = self.frontend.writer();
        var line_count = first_line_number;
        const max_line_number_width = numberWidth(max_line_number);
        var line_it = std.mem.split(string, "\n");
        while (line_it.next()) |line| : (line_count += 1) {
            // When there's a trailing newline, we don't display the very last row.
            if (line_count == max_line_number and line.len == 0) break;

            try w.writeByteNTimes(' ', max_line_number_width - numberWidth(line_count));
            try w.print("{d} {s}\n", .{ line_count, line });
        }
        try self.frontend.ccMoveCursor(1, 1);
        try self.frontend.ccShowCursor();
        try self.frontend.refresh();
    }

    pub inline fn textAreaRows(self: Self) u32 {
        return self.frontend.textAreaRows();
    }

    pub inline fn textAreaCols(self: Self) u32 {
        return self.frontend.textAreaCols();
    }

    pub inline fn next_key(self: *Self) ?Keys.Key {
        return self.frontend.next_key();
    }

    pub fn moveCursor(self: *Self, direction: MoveDirection, number: u32) !void {
        try self.frontend.moveCursor(direction, number);
        try self.frontend.refresh();
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

// TODO: use `Mode`
var current_mode_is_insert = false;

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
                    if (val.utf8[0] == 'q') {
                        current_mode_is_insert = false;
                    } else {
                        try self.dispatch(.{ .value = .{ .insert_character = val.utf8[0] } });
                    }
                } else {
                    switch (val.utf8[0]) {
                        'k' => {
                            try self.text_buffer.display_windows[0].ui.moveCursor(.up, 1);
                        },
                        'j' => {
                            try self.text_buffer.display_windows[0].ui.moveCursor(.down, 1);
                        },
                        'l' => {
                            try self.text_buffer.display_windows[0].ui.moveCursor(.right, 1);
                        },
                        'h' => {
                            try self.text_buffer.display_windows[0].ui.moveCursor(.left, 1);
                        },
                        'i' => {
                            current_mode_is_insert = true;
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

/// `Cursor` represents the current position of a cursor in a display window. `line` and `column`
/// are absolute values inside a file whereas `x` and `y` are relative coordinates to the
/// upper-left corner of the window.
pub const Cursor = struct {
    line: u32,
    column: u32,
    x: u32,
    y: u32,
};

// More possible modes:
// * searching inside a file
// * typing in a command to execute
// * moving inside a file
// * ...
//
// More generally we can have these patterns for modes:
// * Type a full string and press Enter, e.g. type a named command to be executed
// * Type a string and we get an incremental changing of the result, e.g. search window
//   continuously displays different result based on the search term
// * Type a second key to complete the command, e.g. gj moves to the bottom and gk moves to the top
//   of a file, as a mnemocis "goto" and a direction with hjkl keys
// * Variation of the previous mode but it is "sticky", meaning it allows for several presses of
//   a key with a changed meaning, examples are "insert" mode and a "scrolling" mode

/// Modes are different states of a display window which allow to interpret same keys as having
/// a different meaning.
pub const Mode = enum {
    normal,
    insert,
};

/// Manages the data of what the user sees on the screen. Sends all the necessary data
/// to UI to display it on the screen. Also keeps the state of the opened window such
/// as cursor, mode etc.
pub const DisplayWindow = struct {
    rows: u32,
    cols: u32,
    text_buffer: *TextBuffer,
    cursor: Cursor,
    first_line_number: u32,
    mode: Mode,

    const Self = @This();
    const Error = UI.Error || TextBuffer.Error;

    pub fn init(text_buffer: *TextBuffer, rows: u32, cols: u32) Self {
        return Self{
            // .rows = ui.textAreaRows(),
            // .cols = ui.textAreaCols(),
            .rows = rows,
            .cols = cols,
            .text_buffer = text_buffer,
            .cursor = Cursor{ .line = 1, .column = 1, .x = 0, .y = 0 },
            .first_line_number = 1,
            .mode = Mode.normal,
        };
    }

    pub fn renderTextArea(self: *Self) Error![]u8 {
        const last_line_number = self.first_line_number + self.rows;
        const slice = try self.text_buffer.toLineSlice(self.first_line_number, last_line_number);
        var text_area = std.ArrayList(u8).init(self.text_buffer.ally);
        try text_area.writer().print("{s}|{d}|{d}", .{
            slice,
            self.first_line_number,
            self.text_buffer.max_line_number,
        });
        return text_area.toOwnedSlice();
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

pub const Client = struct {
    ally: *std.mem.Allocator,
    // TODO: better name like PipePair
    server_pipe_fds: [2]os.fd_t,
    ui: UI,

    const Self = @This();

    pub fn init(ally: *std.mem.Allocator, server_pipe_fds: [2]os.fd_t, ui: UI) Self {
        return Self{
            .ally = ally,
            .server_pipe_fds = server_pipe_fds,
            .ui = ui,
        };
    }

    // TODO: better name
    pub fn accept(self: *Client) !void {
        const read_end = self.server_pipe_fds[0];
        // const write_end = self.server_pipe_fds[1];
        var read_stream = std.fs.File{
            .handle = read_end,
            .capable_io_mode = .blocking,
            .intended_io_mode = .blocking,
        };
        var buf = [_]u8{0} ** 4096;
        const bytes_read = try read_stream.reader().readAll(buf[0..]);
        var split_it = std.mem.split(buf[0..bytes_read], "|");
        const slice = split_it.next().?;
        const first_line_number = try std.fmt.parseInt(u32, split_it.next().?, 10);
        const max_line_number = try std.fmt.parseInt(u32, split_it.next().?, 10);
        try self.ui.draw(slice, first_line_number, max_line_number);
    }
};

pub const Server = struct {
    ally: *std.mem.Allocator,
    // TODO: better name
    clients: std.ArrayList(ClientPipeFds),
    text_buffers: std.ArrayList(*TextBuffer),
    display_windows: std.ArrayList(*DisplayWindow),

    const Self = @This();
    const ClientPipeFds = [2]os.fd_t;

    pub fn init(ally: *std.mem.Allocator, client: ClientPipeFds, initial_text: []const u8) !Self {
        var clients = std.ArrayList(ClientPipeFds).init(ally);
        try clients.append(client);

        var text_buffers = std.ArrayList(*TextBuffer).init(ally);
        var text_buffer_ptr = try ally.create(TextBuffer);
        text_buffer_ptr.* = try TextBuffer.init(ally, initial_text);
        try text_buffers.append(text_buffer_ptr);

        var display_windows = std.ArrayList(*DisplayWindow).init(ally);
        var display_window_ptr = try ally.create(DisplayWindow);
        display_window_ptr.* = DisplayWindow.init(text_buffer_ptr, 5, 100);
        try display_windows.append(display_window_ptr);

        text_buffers.items[0].display_windows[0] = display_window_ptr;

        return Self{
            .ally = ally,
            .clients = clients,
            // TODO: change interface to do duplication right in this function
            .text_buffers = text_buffers,
            .display_windows = display_windows,
        };
    }

    // TODO: better name
    pub fn send_text(self: *Server) !void {
        var client = self.clients.items[0];
        var text_buffer = self.text_buffers.items[0];
        var display_window = text_buffer.display_windows[0];
        const message = try display_window.renderTextArea();
        // TODO: better name
        var write_stream = std.fs.File{
            .handle = client[1],
            .capable_io_mode = .blocking,
            .intended_io_mode = .blocking,
        };
        try write_stream.writer().writeAll(message);
    }
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ally = &arena.allocator;

    const client_reads_server_writes = try os.pipe();
    const server_reads_client_writes = try os.pipe();
    const client_reads = client_reads_server_writes[0];
    const client_writes = server_reads_client_writes[1];
    const server_reads = server_reads_client_writes[0];
    const server_writes = client_reads_server_writes[1];
    const child_pid = try os.fork();
    if (child_pid == 0) {
        // Server
        os.close(client_reads);
        os.close(client_writes);

        const content = readInput(ally) catch |err| switch (err) {
            error.FileNotSupplied => {
                std.debug.print("No file supplied\n{s}", .{help_string});
                std.os.exit(1);
            },
            else => return err,
        };
        // var text_buffer = try TextBuffer.init(ally, content);
        // var display_window = DisplayWindow.init(&text_buffer);
        // // FIXME: not keep window on the stack
        // text_buffer.display_windows[0] = &display_window;
        // try display_window.render();

        var server = try Server.init(ally, [2]os.fd_t{ server_reads, server_writes }, content);
        try server.send_text();
    } else {
        // Client
        os.close(server_reads);
        os.close(server_writes);

        var uivt100 = try UIVT100.init();
        defer uivt100.deinit() catch {
            std.debug.print("UIVT100 deinit ERRROR", .{});
            std.os.exit(1);
        };
        var ui = UI.init(uivt100);
        var client = Client.init(ally, [2]os.fd_t{ client_reads, client_writes }, ui);
        try client.accept();
        while (true) {}

        // var event_dispatcher = EventDispatcher.init(&text_buffer);
        // while (true) {
        //     if (ui.next_key()) |key| {
        //         switch (key.code) {
        //             .unicode_codepoint => {
        //                 if (key.is_ctrl('c')) {
        //                     break;
        //                 } else {
        //                     try event_dispatcher.dispatch(.{ .value = .{ .key_press = key } });
        //                 }
        //             },
        //             else => {
        //                 std.debug.print("Unrecognized key event: {}\r\n", .{key});
        //                 std.os.exit(1);
        //             },
        //         }
        //     }

        //     std.time.sleep(10 * std.time.ns_per_ms);
        // }
    }
}

/// Representation of a frontend-agnostic "key" which is supposed to encode any possible key
/// unambiguously. All UI frontends are supposed to provide a `Key` struct out of their `next_key`
/// function for consumption by the backend.
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

/// UI frontent. VT100 is an old hardware terminal from 1978. Although it lacks a lot of capabilities
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

        // Black magic, see https://github.com/antirez/kilo
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
        try uivt100.refresh();

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
    // * raw_writer - we don't try to do anything smart, mostly for console codes
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
        try self.ccEraseDisplay();
        try self.ccMoveCursor(1, 1);
    }

    // All our output is buffered, when we actually want to display something to the screen,
    // this function should be called. Buffered output is better for performance and it
    // avoids cursor flickering.
    // This function should not be used as a part of other functions inside a frontend
    // implementation. Instead it should be used inside `UI` for building more complex
    // control flows.
    pub fn refresh(self: *Self) !void {
        try self.buffered_writer_ctx.flush();
    }

    pub fn textAreaRows(self: Self) u32 {
        return self.rows - status_line_width;
    }

    pub fn textAreaCols(self: Self) u32 {
        return self.cols;
    }

    pub fn moveCursor(self: *Self, direction: MoveDirection, number: u32) !void {
        switch (direction) {
            .up => {
                try self.ccMoveCursorUp(number);
            },
            .down => {
                try self.ccMoveCursorDown(number);
            },
            .right => {
                try self.ccMoveCursorRight(number);
            },
            .left => {
                try self.ccMoveCursorLeft(number);
            },
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

    // "cc" stands for "console code", see console_codes(4).
    // Some of the names clash with the desired names of public-facing API functions,
    // so we use a prefix to disambiguate them. Every console code should be in a separate
    // function so that it has a name and has an easy opportunity for parameterization.

    fn ccEraseDisplay(self: *Self) !void {
        try self.raw_writer().print("{s}2J", .{csi});
    }
    fn ccMoveCursor(self: *Self, row: u32, col: u32) !void {
        try self.raw_writer().print("{s}{d};{d}H", .{ csi, row, col });
    }
    fn ccMoveCursorUp(self: *Self, number: u32) !void {
        try self.raw_writer().print("{s}{d}A", .{ csi, number });
    }
    fn ccMoveCursorDown(self: *Self, number: u32) !void {
        try self.raw_writer().print("{s}{d}B", .{ csi, number });
    }
    fn ccMoveCursorRight(self: *Self, number: u32) !void {
        try self.raw_writer().print("{s}{d}C", .{ csi, number });
    }
    fn ccMoveCursorLeft(self: *Self, number: u32) !void {
        try self.raw_writer().print("{s}{d}D", .{ csi, number });
    }
    fn ccHideCursor(self: *Self) !void {
        try self.raw_writer().print("{s}?25l", .{csi});
    }
    fn ccShowCursor(self: *Self) !void {
        try self.raw_writer().print("{s}?25h", .{csi});
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
