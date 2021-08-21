const std = @import("std");
const testing = std.testing;
const os = std.os;
const io = std.io;
const mem = std.mem;
const net = std.net;
const assert = std.debug.assert;
const kisa = @import("kisa");
const rpc = @import("rpc.zig");
const state = @import("state.zig");
const Config = @import("config.zig").Config;
const transport = @import("transport.zig");

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

/// Commands and occasionally queries is a general interface for interacting with the State
/// of a text editor.
pub const Commands = struct {
    workspace: *state.Workspace,

    const Self = @This();

    pub fn openFile(
        self: Self,
        client: Server.ClientRepresentation,
        path: []const u8,
    ) !void {
        // TODO: open existing text buffer.
        client.state.active_display_state = try self.workspace.newTextBuffer(
            client.state.active_display_state,
            state.TextBuffer.InitParams{
                .path = path,
                .name = path,
                .content = null,
            },
        );
        try client.send(rpc.ackResponse(client.last_request_id));
    }

    pub fn redraw(self: Self, client: Server.ClientRepresentation) !void {
        const draw_data = self.workspace.getDrawData(client.state.active_display_state);
        const message = rpc.response(kisa.DrawData, client.last_request_id, draw_data);
        try client.send(message);
    }

    /// Caller owns the memory.
    fn openFileAndRead(ally: *mem.Allocator, path: []const u8) ![]u8 {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(ally, std.math.maxInt(usize));
    }
};

pub const Server = struct {
    ally: *mem.Allocator,
    config: Config,
    watcher: transport.Watcher,
    workspace: state.Workspace,
    clients: std.ArrayList(state.Client),
    commands: Commands,
    last_client_id: state.Workspace.Id = 0,

    const Self = @This();

    pub const ClientRepresentation = struct {
        comms: transport.CommunicationResources,
        state: *state.Client,
        last_request_id: u32 = 0,

        pub usingnamespace transport.CommunicationMixin(@This());
    };

    /// `initDynamic` must be called right after `init`.
    pub fn init(ally: *mem.Allocator, address: *net.Address) !Self {
        defer ally.destroy(address);
        const listen_socket = try transport.bindUnixSocket(address);
        var watcher = transport.Watcher.init(ally);
        try watcher.addListenSocket(listen_socket, 0);
        var workspace = state.Workspace.init(ally);
        try workspace.initDefaultBuffers();
        return Self{
            .ally = ally,
            .config = try readConfig(ally),
            .watcher = watcher,
            .workspace = workspace,
            .clients = std.ArrayList(state.Client).init(ally),
            .commands = undefined,
        };
    }

    /// Initializes all the elements with dynamic memory which would require to reference
    /// objects from the stack if it were in `init`, resulting in error.
    /// Must be called right after `init`.
    pub fn initDynamic(self: *Self) void {
        self.commands = Commands{ .workspace = &self.workspace };
    }

    pub fn deinit(self: *Self) void {
        self.config.deinit();
        self.watcher.deinit();
        self.workspace.deinit();
        for (self.clients.items) |*client| client.deinit();
        self.clients.deinit();
    }

    fn findClient(self: Self, id: state.Workspace.Id) ?ClientRepresentation {
        const watcher_result = self.watcher.findFileDescriptor(id) orelse return null;
        const client = blk: {
            for (self.clients.items) |*client| {
                if (client.id == id) {
                    break :blk client;
                }
            }
            return null;
        };
        return ClientRepresentation{
            .comms = transport.CommunicationResources.initWithUnixSocket(watcher_result.fd),
            .state = client,
        };
    }

    fn addClient(
        self: *Self,
        id: state.Workspace.Id,
        socket: os.socket_t,
        active_display_state: state.ActiveDisplayState,
    ) !ClientRepresentation {
        try self.watcher.addConnectionSocket(socket, id);
        errdefer self.watcher.removeFileDescriptor(id);
        const client = try self.clients.addOne();
        client.* = state.Client{ .id = id, .active_display_state = active_display_state };
        return ClientRepresentation{
            .comms = transport.CommunicationResources.initWithUnixSocket(socket),
            .state = client,
        };
    }

    fn removeClient(self: *Self, id: state.Workspace.Id) void {
        self.watcher.removeFileDescriptor(id);
        for (self.clients.items) |client, idx| {
            if (client.id == id) {
                _ = self.clients.swapRemove(idx);
                break;
            }
        }
    }

    // TODO: send errors to client.
    /// Main loop of the server, listens for requests and sends responses.
    pub fn loop(self: *Self) !void {
        var packet_buf: [transport.max_packet_size]u8 = undefined;
        var method_buf: [transport.max_method_size]u8 = undefined;
        var message_buf: [transport.max_message_size]u8 = undefined;
        while (true) {
            switch (try self.watcher.pollReadable()) {
                .success => |polled_data| {
                    switch (polled_data.ty) {
                        .listen_socket => {
                            const accepted_socket = try os.accept(polled_data.fd, null, null, 0);
                            const client_id = self.nextClientId();
                            const client = try self.addClient(
                                client_id,
                                accepted_socket,
                                // This `empty` is similar to `undefined`, we can't use it and have
                                // to initialize first. With `empty` errors should be better. We can
                                // also make it nullable but it's a pain to always account for a
                                // nullable field.
                                state.ActiveDisplayState.empty,
                            );
                            errdefer self.removeClient(client_id);
                            try client.send(rpc.ackResponse(client.last_request_id));
                        },
                        .connection_socket => {
                            // TODO: check if active display state is empty but we try to do something.
                            var client = self.findClient(polled_data.id) orelse return error.ClientNotFound;
                            const packet = (try client.readPacket(&packet_buf)) orelse return error.EmptyPacket;
                            if (rpc.parseId(packet)) |request_id| {
                                client.last_request_id = request_id orelse return error.NullIdInRequest;
                            } else |err| {
                                // Could be a notification with absent ID.
                                if (err != error.MissingField) {
                                    return err;
                                }
                            }
                            const method_str = try rpc.parseMethod(&method_buf, packet);
                            const method = std.meta.stringToEnum(
                                kisa.CommandKind,
                                method_str,
                            ) orelse std.debug.panic("Unknown rpc method from client: {s}\n", .{method_str});
                            switch (method) {
                                .keypress => {
                                    // TODO: change command and handling in general
                                    const keypress_message = try rpc.KeypressRequest.parse(
                                        &message_buf,
                                        packet,
                                    );
                                    std.debug.print("keypress_message: {}\n", .{keypress_message});
                                },
                                .open_file => {
                                    const command = try rpc.parseCommandFromRequest(
                                        .open_file,
                                        &message_buf,
                                        packet,
                                    );
                                    try self.commands.openFile(client, command.open_file.path);
                                },
                                .redraw => {
                                    _ = try rpc.parseCommandFromRequest(
                                        .redraw,
                                        &message_buf,
                                        packet,
                                    );
                                    try self.commands.redraw(client);
                                },
                                .initialize => {
                                    // TODO: error handling.
                                    const command = try rpc.parseCommandFromRequest(
                                        .initialize,
                                        &message_buf,
                                        packet,
                                    );
                                    const client_init_params = command.initialize;
                                    for (self.clients.items) |*c| {
                                        if (client.state.id == c.id) {
                                            c.active_display_state = try self.workspace.new(
                                                state.TextBuffer.InitParams{
                                                    .content = null,
                                                    .path = client_init_params.path,
                                                    .name = client_init_params.path,
                                                    .readonly = client_init_params.readonly,
                                                },
                                                state.WindowPane.InitParams{
                                                    .text_area_rows = client_init_params.text_area_rows,
                                                    .text_area_cols = client_init_params.text_area_cols,
                                                },
                                            );
                                            break;
                                        }
                                    }
                                    try client.send(rpc.ackResponse(client.last_request_id));
                                },
                                .quitted => {
                                    self.removeClient(polled_data.id);
                                    if (self.watcher.fds.len == 1) {
                                        self.deinit();
                                        break;
                                    }
                                },
                                else => @panic("Not implemented"),
                            }
                        },
                    }
                },
                .err => |polled_data| {
                    self.removeClient(polled_data.id);
                    if (self.watcher.fds.len == 1) {
                        self.deinit();
                        break;
                    }
                },
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

    // Ids start at 1 so that for `Watcher` 0 is reserved for a listen socket.
    fn nextClientId(self: *Self) state.Workspace.Id {
        self.last_client_id += 1;
        return self.last_client_id;
    }
};

/// How Client sees the Server.
pub const ServerForClient = struct {
    comms: transport.CommunicationResources,

    const Self = @This();

    pub fn deinit(self: Self) void {
        self.deinitComms();
    }

    pub usingnamespace transport.CommunicationMixin(@This());
};

pub const Application = struct {
    client: Client,
    /// In threaded mode we call `join` on `deinit`. In not threaded mode this field is `null`.
    server_thread: ?*std.Thread = null,
    // This is post 0.8 version.
    // server_thread: ?std.Thread = null,

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
    ) !?Self {
        const unix_socket_path = try transport.pathForUnixSocket(ally);
        defer ally.free(unix_socket_path);
        const address = try transport.addressForUnixSocket(ally, unix_socket_path);

        switch (concurrency_model) {
            .forked => {
                const child_pid = try os.fork();
                if (child_pid == 0) {
                    // Server

                    // Close stdout and stdin on the server since we don't use them.
                    os.close(io.getStdIn().handle);
                    os.close(io.getStdOut().handle);

                    // This is post 0.8 version.
                    // try startServer(ally, address);
                    try startServer(.{ .ally = ally, .address = address });
                    return null;
                } else {
                    // Client
                    var uivt100 = try UIVT100.init();
                    var ui = UI.init(uivt100);
                    var client = Client.init(ally, ui);
                    try client.register(address);
                    return Self{ .client = client };
                }
            },
            .threaded => {
                // This is post 0.8 version.
                // const server_thread = try std.Thread.spawn(.{}, startServer, .{ ally, address });
                const server_thread = try std.Thread.spawn(startServer, .{ .ally = ally, .address = address });
                var uivt100 = try UIVT100.init();
                var ui = UI.init(uivt100);
                var client = Client.init(ally, ui);
                const address_for_client = try ally.create(net.Address);
                address_for_client.* = address.*;
                try client.register(address_for_client);
                return Self{ .client = client, .server_thread = server_thread };
            },
        }
        unreachable;
    }

    fn startServer(arg: struct { ally: *mem.Allocator, address: *net.Address }) !void {
        var server = try Server.init(arg.ally, arg.address);
        server.initDynamic();
        errdefer server.deinit();
        try server.loop();
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        if (self.server_thread) |server_thread| {
            // This is post 0.8 version.
            // server_thread.join();
            server_thread.wait();
            self.server_thread = null;
        }
    }
};

pub const Client = struct {
    ally: *mem.Allocator,
    ui: UI,
    server: ServerForClient,
    last_message_id: u32 = 0,

    const Self = @This();

    pub fn init(ally: *mem.Allocator, ui: UI) Self {
        return Self{
            .ally = ally,
            .ui = ui,
            .server = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        const message = rpc.emptyNotification("quitted");
        self.server.send(message) catch {};
        // TEST: Check for race conditions.
        // std.time.sleep(std.time.ns_per_s * 1);
        self.server.deinitComms();
    }

    pub fn register(self: *Self, address: *net.Address) !void {
        defer self.ally.destroy(address);
        self.server = ServerForClient.initWithUnixSocket(
            try transport.connectToUnixSocket(address),
        );
        var request_buf: [transport.max_method_size]u8 = undefined;
        // TODO: use waitForResponse
        const response = (try self.server.recv(rpc.EmptyResponse, &request_buf)).?;
        assert(response == .Success);
        const message_id = self.nextMessageId();
        const message = rpc.commandRequest(
            .initialize,
            message_id,
            .{
                .path = "/home/grfork/reps/kisa/kisarc.zzz",
                .readonly = false,
                .text_area_rows = 80,
                .text_area_cols = 24,
            },
        );
        try self.server.send(message);
        try self.waitForResponse(message_id);
    }

    pub fn sendKeypress(self: *Client, key: Keys.Key) !void {
        const id = self.nextMessageId();
        const message = rpc.KeypressRequest.init(
            .{ .Integer = id },
            "keypress",
            key,
        );
        try message.writeTo(self.server.writer());
        try self.server.writeEndByte();
        try self.waitForResponse(id);
    }

    // It only returns `DrawData` for testing purposes, probably should be `void` instead.
    pub fn edit(self: *Client, path: []const u8) !kisa.DrawData {
        try self.openFile(path);
        return try self.requestDrawData();
    }

    fn openFile(self: *Client, path: []const u8) !void {
        const id = self.nextMessageId();
        const message = rpc.commandRequest(.open_file, id, .{ .path = path });
        try self.server.send(message);
        try self.waitForResponse(id);
    }

    fn requestDrawData(self: *Client) !kisa.DrawData {
        const id = self.nextMessageId();
        const message = rpc.emptyCommandRequest(.redraw, id);
        try self.server.send(message);
        return try self.receiveDrawData(@intCast(u32, id));
    }

    fn receiveDrawData(self: *Client, id: u32) !kisa.DrawData {
        var message_buf: [transport.max_message_size]u8 = undefined;
        // TODO: better API for response construction
        const response = try self.receiveResponse(id, rpc.Response(kisa.DrawData), &message_buf);
        return response.Success.result;
    }

    fn waitForResponse(self: *Self, id: u32) !void {
        var message_buf: [transport.max_message_size]u8 = undefined;
        const response = (try self.server.recv(
            rpc.EmptyResponse,
            &message_buf,
        )) orelse return error.ServerClosedConnection;
        switch (response) {
            .Success => |s| {
                if (s.id) |response_id| {
                    if (!std.meta.eql(id, response_id)) return error.InvalidResponseId;
                } else {
                    return error.ReceivedNullId;
                }
            },
            .Error => return error.ErrorResponse,
        }
    }

    fn receiveResponse(
        self: *Self,
        id: u32,
        comptime Message: type,
        message_buf: []u8,
    ) !Message {
        const response = (try self.server.recv(
            Message,
            message_buf,
        )) orelse return error.ServerClosedConnection;
        switch (response) {
            .Success => |s| {
                if (!std.meta.eql(id, s.id.?)) return error.InvalidResponseId;
                return response;
            },
            .Error => return error.ErrorResponse,
        }
    }

    pub fn nextMessageId(self: *Self) u32 {
        self.last_message_id += 1;
        return self.last_message_id;
    }
};

test "main: start application threaded via socket" {
    if (try Application.start(testing.allocator, .threaded)) |*app| {
        defer app.deinit();
        var client = app.client;
        const draw_data = try client.edit("/home/grfork/reps/kisa/kisarc.zzz");
        try testing.expectEqual(@as(usize, 1), draw_data.lines.len);
        try testing.expectEqual(@as(u32, 1), draw_data.lines[0].number);
        try testing.expectEqualStrings("hello", draw_data.lines[0].contents);
    }
}

test "fork/socket: start application forked via socket" {
    if (try Application.start(testing.allocator, .forked)) |*app| {
        defer app.deinit();
        var client = app.client;
        const draw_data = try client.edit("/home/grfork/reps/kisa/kisarc.zzz");
        try testing.expectEqual(@as(usize, 1), draw_data.lines.len);
        try testing.expectEqual(@as(u32, 1), draw_data.lines[0].number);
        try testing.expectEqualStrings("hello", draw_data.lines[0].contents);
    }
}

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

    if (try Application.start(ally, .threaded)) |app| {
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

        fn utf8len(self: Key) usize {
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
