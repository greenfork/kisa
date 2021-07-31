const std = @import("std");
const testing = std.testing;
const os = std.os;
const io = std.io;
const mem = std.mem;
const jsonrpc = @import("jsonrpc.zig");
const Config = @import("config.zig").Config;

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
        var line_it = mem.split(string, "\n");
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

    pub inline fn setup(self: *Self) !void {
        try self.frontend.setup();
    }

    pub inline fn teardown(self: *Self) void {
        self.frontend.teardown();
    }
};

pub const EventKind = enum {
    noop,
    insert_character,
    cursor_move_down,
    cursor_move_left,
    cursor_move_up,
    cursor_move_right,
    quit,
    save,
    delete_word,
    delete_line,
};

/// Event is a generic notion of an action happenning on the server, usually as a response to
/// client actions.
pub const Event = union(EventKind) {
    noop,
    quit,
    save,
    /// Value is inserted character.
    insert_character: u8,
    /// Value is multiplier.
    cursor_move_down: u32,
    /// Value is multiplier.
    cursor_move_left: u32,
    /// Value is multiplier.
    cursor_move_up: u32,
    /// Value is multiplier.
    cursor_move_right: u32,
    /// Value is multiplier.
    delete_word: u32,
    /// Value is multiplier.
    delete_line: u32,
};

/// Event dispatcher processes any events happening on the server. The result is usually
/// mutation of state, firing of registered hooks if any, and sending response back to client.
pub const EventDispatcher = struct {
    const Self = @This();

    pub fn init() Self {
        return .{ .text_buffer = text_buffer };
    }

    pub fn dispatch(self: Self, event: Event) !void {
        switch (event) {
            .noop => {},
            .quit => {},
            .save => {},
            .insert_character => |val| {
                self.cmd.insertCharacter(val);
            },
            .cursor_move_down => {},
            .cursor_move_left => {},
            .cursor_move_up => {},
            .cursor_move_right => {},
            .delete_word => {},
            .delete_line => {},
        }
    }
};

/// Commands and occasionally queries is a general interface for interacting with the State
/// of a text editor.
pub const Commands = struct {
    pub fn init() Commands {
        return Commands{};
    }
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

pub const Client = struct {
    ally: *mem.Allocator,
    ui: UI,
    server: ClientServerRepresentation,
    // TODO: add client ID which is received from the Server on connect.
    last_message_id: u32 = 0,

    const Self = @This();

    pub fn init(ally: *mem.Allocator, ui: UI, server: ClientServerRepresentation) Self {
        return Self{
            .ally = ally,
            .server = server,
            .ui = ui,
        };
    }

    pub fn deinit(self: *Self) void {
        self.sendExitNotify() catch unreachable;
        self.server.deinit();
    }

    /// Notify the server that this client is closing, but send a synchronous jsonrpc request,
    /// we want to receive an acknowledgement from the server.
    pub fn sendExitNotify(self: *Client) !void {
        var message = self.emptyJsonRpcRequest();
        message.method = "exitNotify";
        // TODO: 1 should be changed to id or something.
        message.params = .{ .Integer = 1 };
        try message.writeTo(self.server.writer());
        try self.server.writeEndByte();
        try self.waitForResponse(message.id);
    }

    // TODO: better name
    pub fn acceptText(self: *Client) !void {
        var packet_buf: [ClientServerRepresentation.max_packet_size]u8 = undefined;
        var message_buf: [ClientServerRepresentation.max_packet_size]u8 = undefined;
        const packet = try self.server.readPacket(&packet_buf);
        const message = try jsonrpc.SimpleRequest.parseAlloc(&message_buf, packet);
        if (mem.eql(u8, "draw", message.method)) {
            const params = message.params.Array;
            try self.ui.draw(
                params[0].String,
                @intCast(u32, params[1].Integer),
                @intCast(u32, params[1].Integer),
            );
        } else {
            return error.UnrecognizedMethod;
        }
    }

    pub fn sendFileToOpen(self: *Client, filename: []u8) !void {
        self.last_message_id += 1;
        var message = self.emptyJsonRpcRequest();
        message.method = "openFile";
        message.params = .{ .String = filename };
        try message.writeTo(self.server.writer());
        try self.server.writeEndByte();
    }

    pub fn sendKeypress(self: *Client, key: Keys.Key) !void {
        const id = @intCast(i64, self.nextMessageId());
        const message = KeypressRequest.init(
            .{ .Integer = id },
            "keypress",
            key,
        );
        try message.writeTo(self.server.writer());
        try self.server.writeEndByte();
        try self.waitForResponse(id);
    }

    pub fn waitForResponse(self: *Self, id: ?jsonrpc.IdValue) !void {
        const response_packet = try self.server.readPacketAlloc(self.ally);
        defer self.ally.free(response_packet);
        const response = try jsonrpc.SimpleResponse.parseAlloc(self.ally, response_packet);
        defer response.parseFree(self.ally);
        if (response.result != null) {
            if (!std.meta.eql(id, response.id)) {
                return error.InvalidIdInResponse;
            }
        } else {
            return error.ErrorResponse;
        }
    }

    pub fn nextMessageId(self: *Self) u32 {
        self.last_message_id += 1;
        return self.last_message_id;
    }

    /// Caller owns the memory.
    fn filePathForReading(ally: *mem.Allocator) ![]u8 {
        var arg_it = std.process.args();
        _ = try arg_it.next(ally) orelse unreachable;
        if (arg_it.next(ally)) |file_name_delimited| {
            return try std.fs.cwd().realpathAlloc(ally, try file_name_delimited);
        } else {
            return error.FileNotSupplied;
        }
    }

    fn emptyJsonRpcRequest(self: *Self) jsonrpc.SimpleRequest {
        return jsonrpc.SimpleRequest{
            .jsonrpc = jsonrpc.jsonrpc_version,
            .id = .{ .Integer = self.nextMessageId() },
            .method = undefined,
            .params = undefined,
        };
    }
};

pub const Server = struct {
    ally: *mem.Allocator,
    clients: std.ArrayList(ClientServerRepresentation),
    config: Config,

    const Self = @This();

    pub fn init(ally: *mem.Allocator, client: ClientServerRepresentation) !Self {
        var clients = std.ArrayList(ClientServerRepresentation).init(ally);
        try clients.append(client);

        return Self{
            .ally = ally,
            .clients = clients,
            .config = try readConfig(ally),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.clients.items) |*client| client.deinit();
        self.clients.deinit();
        self.config.deinit();
    }

    // TODO: text buffer
    pub fn createNewTextBuffer(self: *Self, text: []const u8) !void {
        _ = self;
        _ = text;
        // var text_buffer_ptr = try self.ally.create(TextBuffer);
        // text_buffer_ptr.* = try TextBuffer.init(self.ally, text);
        // try self.text_buffers.append(text_buffer_ptr);

        // var display_window_ptr = try self.ally.create(DisplayWindow);
        // display_window_ptr.* = DisplayWindow.init(text_buffer_ptr, 5, 100);
        // try self.display_windows.append(display_window_ptr);

        // self.text_buffers.items[0].display_windows[0] = display_window_ptr;
    }

    pub fn sendText(self: *Self) !void {
        _ = self;
        // var client = self.clients.items[0];
        // var text_buffer = self.text_buffers.items[0];
        // var display_window = text_buffer.display_windows[0];
        // // TODO: freeing like this does not scale for other messages
        // const message = try display_window.renderTextArea();
        // defer self.ally.free(message.params.Array);
        // try message.writeTo(client.writer());
        // try client.writeEndByte();
    }

    pub fn acceptOpenFileRequest(self: *Self) !void {
        var request_string: []const u8 = try self.clients.items[0].readPacketAlloc(self.ally);
        defer self.ally.free(request_string);
        var request = try jsonrpc.SimpleRequest.parseAlloc(self.ally, request_string);
        defer request.parseFree(self.ally);
        if (mem.eql(u8, "openFile", request.method)) {
            const text = try openFileAndRead(self.ally, request.params.String);
            defer self.ally.free(text);
            try self.createNewTextBuffer(text);
        } else {
            return error.UnrecognizedMethod;
        }
    }

    pub fn loop(self: *Self) !void {
        var packet_buf: [ClientServerRepresentation.max_packet_size]u8 = undefined;
        var method_buf: [ClientServerRepresentation.max_packet_size]u8 = undefined;
        var message_buf: [ClientServerRepresentation.max_packet_size]u8 = undefined;
        while (true) {
            if (try self.clients.items[0].readPacket(&packet_buf)) |packet| {
                const method = try jsonrpc.SimpleRequest.parseMethod(&method_buf, packet);
                if (mem.eql(u8, "keypress", method)) {
                    const keypress_message = try KeypressRequest.parse(&message_buf, packet);
                    std.debug.print("keypress_message: {}\n", .{keypress_message});
                } else if (mem.eql(u8, "exitNotify", method)) {
                    const exit_request_message = try jsonrpc.SimpleRequest.parse(&message_buf, packet);
                    const ack_response = jsonrpc.SimpleResponse.initResult(
                        exit_request_message.id,
                        .{ .Bool = true },
                    );
                    try ack_response.writeTo(self.clients.items[0].writer());
                    try self.clients.items[0].writeEndByte();
                    self.deinit();
                    break;
                } else {
                    @panic("unknown method in server loop");
                }
            }
        }
    }

    fn readConfig(ally: *mem.Allocator) !Config {
        // var path_buf: [256]u8 = undefined;
        // const path = try std.fs.cwd().realpath("kisarc.zzz", &path_buf);
        var config = Config.init(ally);
        try config.setup();
        try config.addConfig(@embedFile("../kisarc.zzz"), true);
        // try config.addConfigFile(path);
        return config;
    }

    /// Caller owns the memory.
    fn openFileAndRead(ally: *mem.Allocator, path: []const u8) ![]u8 {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(ally, std.math.maxInt(usize));
    }
};

pub const Transport = struct {
    client_reads: os.fd_t,
    client_writes: os.fd_t,
    server_reads: os.fd_t,
    server_writes: os.fd_t,
    kind: Kind,

    const Self = @This();

    pub const Kind = enum {
        pipes,
    };

    pub fn init(kind: Kind) !Self {
        switch (kind) {
            .pipes => {
                const client_reads_server_writes = try os.pipe();
                const server_reads_client_writes = try os.pipe();
                return Self{
                    .client_reads = client_reads_server_writes[0],
                    .client_writes = server_reads_client_writes[1],
                    .server_reads = server_reads_client_writes[0],
                    .server_writes = client_reads_server_writes[1],
                    .kind = kind,
                };
            },
        }
        unreachable;
    }

    pub fn serverRepresentationForClient(self: Self) ClientServerRepresentation {
        switch (self.kind) {
            .pipes => {
                return ClientServerRepresentation{
                    .read_stream = self.client_reads,
                    .write_stream = self.client_writes,
                };
            },
        }
        unreachable;
    }

    pub fn clientRepresentationForServer(self: Self) ClientServerRepresentation {
        switch (self.kind) {
            .pipes => {
                return ClientServerRepresentation{
                    .read_stream = self.server_reads,
                    .write_stream = self.server_writes,
                };
            },
        }
        unreachable;
    }

    pub fn closeStreamsForServer(self: Self) void {
        os.close(self.client_reads);
        os.close(self.client_writes);
    }

    pub fn closeStreamsForClient(self: Self) void {
        os.close(self.server_reads);
        os.close(self.server_writes);
    }
};

/// This is how Client sees a Server and how Server sees a Client. We can't use direct pointers
/// to memory since they can be in separate processes. Therefore they see each other as just
/// some ways to send and receive information.
pub const ClientServerRepresentation = struct {
    read_stream: os.fd_t,
    write_stream: os.fd_t,

    const Self = @This();
    // TODO: use just the curly/square braces to determine the end of a message.
    const end_of_message = '\x17';
    pub const max_packet_size: usize = 1024 * 16;

    pub fn deinit(self: Self) void {
        os.close(self.read_stream);
        os.close(self.write_stream);
    }

    pub fn reader(self: Self) std.fs.File.Reader {
        return pipeToFile(self.read_stream).reader();
    }

    /// Returns the slice with the length of a received packet.
    pub fn readPacket(self: Self, buf: []u8) !?[]u8 {
        return try self.reader().readUntilDelimiterOrEof(buf, end_of_message);
    }

    /// Caller owns the memory.
    pub fn readPacketAlloc(self: Self, ally: *mem.Allocator) ![]u8 {
        return try self.reader().readUntilDelimiterAlloc(ally, end_of_message, max_packet_size);
    }

    pub fn writer(self: Self) std.fs.File.Writer {
        return pipeToFile(self.write_stream).writer();
    }

    pub fn writeEndByte(self: Self) !void {
        try self.writer().writeByte(end_of_message);
    }

    fn pipeToFile(fd: os.fd_t) std.fs.File {
        return std.fs.File{
            .handle = fd,
            .capable_io_mode = .blocking,
            .intended_io_mode = .blocking,
        };
    }
};

pub const Application = struct {
    client: Client,

    const Self = @This();

    pub const ConcurrencyModel = enum {
        threaded,
        forked,
    };

    /// Start `Server` instance on background and `Client` instance on foreground. This function
    /// returns `null` when it launches a server instance and no actions should be performed,
    /// currently it is only relevant for `forked` concurrency model. When this function returns
    /// `Application` instance, this is client code.
    pub fn start(
        ally: *mem.Allocator,
        concurrency_model: ConcurrencyModel,
        transport_kind: Transport.Kind,
    ) !?Self {
        switch (concurrency_model) {
            .forked => {
                var transport = try Transport.init(transport_kind);
                const child_pid = try os.fork();
                if (child_pid == 0) {
                    // Server

                    // We only want to keep Client's streams open.
                    transport.closeStreamsForServer();
                    os.close(io.getStdIn().handle);
                    os.close(io.getStdOut().handle);

                    try startServerThread(ally, transport);
                    return null;
                } else {
                    // Client

                    // We only want to keep Server's streams open.
                    transport.closeStreamsForClient();

                    var uivt100 = try UIVT100.init();
                    var ui = UI.init(uivt100);
                    var client = Client.init(ally, ui, transport.serverRepresentationForClient());
                    return Self{ .client = client };
                }
            },
            .threaded => {
                const transport = try Transport.init(transport_kind);
                const server_thread = try std.Thread.spawn(
                    .{},
                    startServerThread,
                    .{ ally, transport },
                );
                server_thread.detach();

                var uivt100 = try UIVT100.init();
                var ui = UI.init(uivt100);
                var client = Client.init(ally, ui, transport.serverRepresentationForClient());
                return Self{ .client = client };
            },
        }
        unreachable;
    }

    fn startServerThread(ally: *mem.Allocator, transport: Transport) !void {
        var server = try Server.init(ally, transport.clientRepresentationForServer());
        errdefer server.deinit();
        // try server.acceptOpenFileRequest();
        // try server.sendText();
        try server.loop();
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }
};

test "main: start application threaded via pipes" {
    var filename = try std.fs.cwd().realpathAlloc(testing.allocator, "tests/longlines.txt");
    defer testing.allocator.free(filename);
    if (try Application.start(testing.allocator, .threaded, .pipes)) |*app| {
        defer app.deinit();
    }
}

test "main: start application forked via pipes" {
    if (try Application.start(testing.allocator, .forked, .pipes)) |*app| {
        defer app.deinit();
    }
}

// test "main: request client registration" {
//     if (try Application.start(testing.allocator, .threaded, .pipes)) |*app| {
//         defer app.deinit();
//     }
// }

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ally = &gpa.allocator;

    var arg_it = std.process.args();
    _ = try arg_it.next(ally) orelse unreachable;
    const filename = blk: {
        if (arg_it.next(ally)) |file_name_delimited| {
            break :blk try std.fs.cwd().realpathAlloc(ally, try file_name_delimited);
        } else {
            return error.FileNotSupplied;
        }
    };

    if (try Application.start(ally, .threaded, .pipes)) |app| {
        var client = app.client;
        try client.ui.setup();
        defer client.ui.teardown();

        try client.sendFileToOpen(filename);
        try client.acceptText();

        while (true) {
            if (client.ui.next_key()) |key| {
                switch (key.code) {
                    .unicode_codepoint => {
                        if (key.isCtrl('c')) {
                            break;
                        }
                        try client.sendKeypress(key);
                    },
                    else => {
                        std.debug.print("Unrecognized key type: {}\r\n", .{key});
                        std.os.exit(1);
                    },
                }
            }
        }
    }
}

pub const KeypressRequest = jsonrpc.Request(Keys.Key);

/// Representation of a frontend-agnostic "key" which is supposed to encode any possible key
/// unambiguously. All UI frontends are supposed to provide a `Key` struct out of their `next_key`
/// function for consumption by the backend.
pub const Keys = struct {
    pub const KeySym = enum {
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,

        pub fn jsonStringify(
            value: KeySym,
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            _ = options;
            try out_stream.writeAll(std.meta.tagName(value));
        }
    };

    pub const MouseButton = enum {
        left,
        middle,
        right,
        scroll_up,
        scroll_down,

        pub fn jsonStringify(
            value: MouseButton,
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            _ = options;
            try out_stream.writeAll(std.meta.tagName(value));
        }
    };

    pub const KeyCode = union(enum) {
        // How to represent a null value? See discussions below
        // https://github.com/ziglang/zig/issues/9415
        // https://github.com/greenfork/kisa/commit/23cfb17ae335dfe044eb4f1cd798deb37b48d569#r53652535
        // unrecognized: u0,
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

        pub fn hasShift(self: Key) bool {
            return (self.modifiers & shift_bit) != 0;
        }
        pub fn hasAlt(self: Key) bool {
            return (self.modifiers & alt_bit) != 0;
        }
        pub fn hasCtrl(self: Key) bool {
            return (self.modifiers & ctrl_bit) != 0;
        }
        pub fn hasSuper(self: Key) bool {
            return (self.modifiers & super_bit) != 0;
        }
        pub fn hasHyper(self: Key) bool {
            return (self.modifiers & hyper_bit) != 0;
        }
        pub fn hasMeta(self: Key) bool {
            return (self.modifiers & meta_bit) != 0;
        }
        pub fn hasCapsLock(self: Key) bool {
            return (self.modifiers & caps_lock_bit) != 0;
        }
        pub fn hasNumLock(self: Key) bool {
            return (self.modifiers & num_lock_bit) != 0;
        }

        pub fn addShift(self: *Key) void {
            self.modifiers = self.modifiers | shift_bit;
        }
        pub fn addAlt(self: *Key) void {
            self.modifiers = self.modifiers | alt_bit;
        }
        pub fn addCtrl(self: *Key) void {
            self.modifiers = self.modifiers | ctrl_bit;
        }
        pub fn addSuper(self: *Key) void {
            self.modifiers = self.modifiers | super_bit;
        }
        pub fn addHyper(self: *Key) void {
            self.modifiers = self.modifiers | hyper_bit;
        }
        pub fn addMeta(self: *Key) void {
            self.modifiers = self.modifiers | meta_bit;
        }
        pub fn addCapsLock(self: *Key) void {
            self.modifiers = self.modifiers | caps_lock_bit;
        }
        pub fn addNumLock(self: *Key) void {
            self.modifiers = self.modifiers | num_lock_bit;
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
        pub fn isAscii(self: Key) bool {
            return self.code == .unicode_codepoint and self.utf8len() == 1;
        }
        pub fn isCtrl(self: Key, character: u8) bool {
            return self.isAscii() and self.utf8[0] == character and self.modifiers == ctrl_bit;
        }

        pub fn ascii(character: u8) Key {
            var key = Key{ .code = .{ .unicode_codepoint = character } };
            key.utf8[0] = character;
            key.utf8[1] = 0;
            return key;
        }
        pub fn ctrl(character: u8) Key {
            var key = ascii(character);
            key.addCtrl();
            return key;
        }
        pub fn alt(character: u8) Key {
            var key = ascii(character);
            key.addAlt();
            return key;
        }
        pub fn shift(character: u8) Key {
            var key = ascii(character);
            key.addShift();
            return key;
        }

        // We don't use `utf8` field for equality because it only contains necessary information
        // to represent other values and must not be considered to be always present.
        pub fn eql(a: Key, b: Key) bool {
            return std.meta.eql(a.code, b.code) and std.meta.eql(a.modifiers, b.modifiers);
        }
        pub fn hash(key: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key.code);
            std.hash.autoHash(&hasher, key.modifiers);
            return hasher.final();
        }

        pub const HashMapContext = struct {
            pub fn hash(self: @This(), s: Key) u64 {
                _ = self;
                return Key.hash(s);
            }
            pub fn eql(self: @This(), a: Key, b: Key) bool {
                _ = self;
                return Key.eql(a, b);
            }
        };

        pub fn format(
            value: Key,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            if (fmt.len == 1 and fmt[0] == 's') {
                try writer.writeAll("Key(");
                if (value.hasNumLock()) try writer.writeAll("num_lock-");
                if (value.hasCapsLock()) try writer.writeAll("caps_lock-");
                if (value.hasMeta()) try writer.writeAll("meta-");
                if (value.hasHyper()) try writer.writeAll("hyper-");
                if (value.hasSuper()) try writer.writeAll("super-");
                if (value.hasCtrl()) try writer.writeAll("ctrl-");
                if (value.hasAlt()) try writer.writeAll("alt-");
                if (value.hasShift()) try writer.writeAll("shift-");
                switch (value.code) {
                    .unicode_codepoint => |val| {
                        try std.fmt.format(writer, "{c}", .{@intCast(u8, val)});
                    },
                    .function => |val| try std.fmt.format(writer, "f{d}", .{val}),
                    .keysym => |val| try std.fmt.format(writer, "{s}", .{std.meta.tagName(val)}),
                    .mouse_button => |val| try std.fmt.format(writer, "{s}", .{std.meta.tagName(val)}),
                    .mouse_position => |val| {
                        try std.fmt.format(writer, "MousePosition({d},{d})", .{ val.x, val.y });
                    },
                }
                try writer.writeAll(")");
            } else if (fmt.len == 0) {
                try std.fmt.format(
                    writer,
                    "{s}{{ .code = {}, .modifiers = {b}, .utf8 = {any} }}",
                    .{ @typeName(@TypeOf(value)), value.code, value.modifiers, value.utf8 },
                );
            } else {
                @compileError("Unknown format character for Key: '" ++ fmt ++ "'");
            }
        }
    };
};

test "main: keys" {
    try std.testing.expect(!Keys.Key.ascii('c').hasCtrl());
    try std.testing.expect(Keys.Key.ctrl('c').hasCtrl());
    try std.testing.expect(Keys.Key.ascii('c').isAscii());
    try std.testing.expect(Keys.Key.ctrl('c').isAscii());
    try std.testing.expect(Keys.Key.ctrl('c').isCtrl('c'));
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
        try uivt100.updateWindowSize();

        return uivt100;
    }

    pub fn setup(self: *Self) Error!void {
        // Black magic, see https://github.com/antirez/kilo
        var raw_termios = self.original_termois.?;
        raw_termios.iflag &=
            ~(@as(os.tcflag_t, os.BRKINT) | os.ICRNL | os.INPCK | os.ISTRIP | os.IXON);
        raw_termios.oflag &= ~(@as(os.tcflag_t, os.OPOST));
        raw_termios.cflag |= os.CS8;
        raw_termios.lflag &= ~(@as(os.tcflag_t, os.ECHO) | os.ICANON | os.IEXTEN | os.ISIG);
        // Polling read, doesn't block
        raw_termios.cc[os.VMIN] = 0;
        raw_termios.cc[os.VTIME] = 0;
        try os.tcsetattr(self.in_stream.handle, os.TCSA.FLUSH, raw_termios);
    }

    pub fn teardown(self: *Self) void {
        if (self.original_termois) |termios| {
            os.tcsetattr(self.in_stream.handle, os.TCSA.FLUSH, termios) catch |err| {
                std.debug.print("UIVT100.teardown failed with {}\n", .{err});
            };
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
