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

    pub fn draw(self: *Self, string: []const u8, first_line_number: u32, max_line_number: u32) !void {
        _ = self;
        _ = string;
        _ = first_line_number;
        _ = max_line_number;
    }

    pub inline fn textAreaRows(self: Self) u32 {
        return self.frontend.textAreaRows();
    }

    pub inline fn textAreaCols(self: Self) u32 {
        return self.frontend.textAreaCols();
    }

    pub inline fn nextKey(self: *Self) ?kisa.Key {
        return self.frontend.nextKey();
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
        client: *Server.ClientRepresentation,
        path: []const u8,
    ) !void {
        // TODO: open existing text buffer.
        client.state.active_display_state = self.workspace.newTextBuffer(
            client.state.active_display_state,
            state.TextBuffer.InitParams{
                .path = path,
                .name = path,
                .contents = null,
                .line_ending = .unix,
            },
        ) catch |err| switch (err) {
            error.InitParamsMustHaveEitherPathOrContent => return error.InvalidParams,
            error.SharingViolation,
            error.OutOfMemory,
            error.OperationAborted,
            error.NotOpenForReading,
            error.InputOutput,
            error.AccessDenied,
            error.SymLinkLoop,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.FileBusy,
            error.FileNotFound,
            error.SystemResources,
            error.NameTooLong,
            error.NoDevice,
            error.DeviceBusy,
            error.FileTooBig,
            error.NoSpaceLeft,
            error.IsDir,
            error.BadPathName,
            error.InvalidUtf8,
            error.Unexpected,
            => |e| return e,
        };
        try client.send(rpc.ackResponse(client.last_request_id));
    }

    // TODO: draw real data.
    pub fn redraw(self: Self, client: *Server.ClientRepresentation) !void {
        const draw_data = self.workspace.draw(client.state.active_display_state);
        const message = rpc.response(kisa.DrawData, client.last_request_id, draw_data);
        try client.send(message);
    }

    // TODO: use multiplier.
    // TODO: draw real data.
    pub fn cursorMoveDown(self: Self, client: *Server.ClientRepresentation, multiplier: u32) !void {
        _ = multiplier;
        try self.redraw(client);
    }
};

pub const Server = struct {
    ally: mem.Allocator,
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
    pub fn init(ally: mem.Allocator, address: *net.Address) !Self {
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

    /// Main loop of the server, listens for requests and sends responses.
    pub fn loop(self: *Self) !void {
        var packet_buf: [transport.max_packet_size]u8 = undefined;
        var method_buf: [transport.max_method_size]u8 = undefined;
        var message_buf: [transport.max_message_size]u8 = undefined;
        while (true) {
            switch ((try self.watcher.pollReadable(-1)).?) {
                .success => |polled_data| {
                    switch (polled_data.ty) {
                        .listen_socket => {
                            try self.processNewConnection(polled_data.fd);
                        },
                        .connection_socket => {
                            var client = self.findClient(polled_data.id).?;
                            self.processClientRequest(
                                &client,
                                &packet_buf,
                                &method_buf,
                                &message_buf,
                            ) catch |err| switch (err) {
                                error.ShouldQuit => break,
                                // Some errors are programming errors.
                                // We don't send non-blocking responses to clients, always block.
                                error.WouldBlock,
                                error.MessageTooBig,
                                // XXX: This error is caught inside Commands, probably a bug that
                                // compiler complains about it not being caught here.
                                error.InitParamsMustHaveEitherPathOrContent,
                                // XXX: This error is caught inside Transport.
                                error.EndOfStream,
                                => unreachable,
                                // For these errors the client is probably wrong and we can send
                                // an error message explaining why.
                                error.EmptyPacket,
                                error.NullIdInRequest,
                                error.ParseError,
                                error.InvalidRequest,
                                error.MethodNotFound,
                                error.InvalidParams,
                                error.InvalidUtf8,
                                error.BadPathName,
                                error.NoSpaceLeft,
                                error.DeviceBusy,
                                error.NoDevice,
                                error.NameTooLong,
                                error.FileBusy,
                                error.FileNotFound,
                                error.SystemFdQuotaExceeded,
                                error.ProcessFdQuotaExceeded,
                                error.SymLinkLoop,
                                error.SharingViolation,
                                error.InputOutput,
                                error.NotOpenForReading,
                                error.OperationAborted,
                                error.IsDir,
                                error.FileTooBig,
                                error.UninitializedClient,
                                error.StreamTooLong,
                                => |e| {
                                    client.send(rpc.errorResponse(client.state.id, e)) catch {
                                        std.debug.print(
                                            "Failed to send error response to client ID {d}: {s}",
                                            .{ client.state.id, @errorName(err) },
                                        );
                                    };
                                },
                                // These errors indicate that we can't use this socket connection.
                                error.BrokenPipe,
                                error.ConnectionResetByPeer,
                                error.AccessDenied,
                                error.NetworkSubsystemFailed,
                                error.SocketNotConnected,
                                error.SocketNotBound,
                                error.ConnectionRefused,
                                => {
                                    self.removeClient(polled_data.id);
                                    if (self.watcher.fds.len == 1) {
                                        self.deinit();
                                        break;
                                    }
                                },
                                // Some errors are unrecoverable or seem impossible.
                                error.FastOpenAlreadyInProgress,
                                error.SystemResources,
                                error.FileDescriptorNotASocket,
                                error.NetworkUnreachable,
                                error.Unexpected,
                                error.OutOfMemory,
                                => return err,
                            };
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

    fn processNewConnection(self: *Self, polled_fd: os.socket_t) !void {
        const accepted_socket = try os.accept(polled_fd, null, null, 0);
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
    }

    fn processClientRequest(
        self: *Self,
        client: *ClientRepresentation,
        packet_buf: []u8,
        method_buf: []u8,
        message_buf: []u8,
    ) !void {
        const packet = (try client.readPacket(packet_buf)) orelse return error.EmptyPacket;
        if (rpc.parseId(packet)) |request_id| {
            client.last_request_id = request_id orelse return error.NullIdInRequest;
        } else |err| switch (err) {
            // Could be a notification with absent ID.
            error.MissingField => client.last_request_id = 0,
            error.ParseError => return error.ParseError,
        }

        const method_str = try rpc.parseMethod(method_buf, packet);
        const method = std.meta.stringToEnum(
            kisa.CommandKind,
            method_str,
        ) orelse {
            std.debug.print("Unknown rpc method from client: {s}\n", .{method_str});
            return error.MethodNotFound;
        };
        if (method != .initialize and
            std.meta.eql(client.state.active_display_state, state.ActiveDisplayState.empty))
        {
            return error.UninitializedClient;
        }
        switch (method) {
            .open_file => {
                const command = try rpc.parseCommandFromRequest(.open_file, message_buf, packet);
                try self.commands.openFile(client, command.open_file.path);
            },
            .redraw => {
                try self.commands.redraw(client);
            },
            .keypress => {
                const key_command = try rpc.parseCommandFromRequest(.keypress, message_buf, packet);
                const command = self.config.resolveKey(key_command.keypress.key);
                switch (command) {
                    .cursor_move_down => {
                        try self.commands.cursorMoveDown(client, key_command.keypress.multiplier);
                    },
                    else => @panic("Not implemented"),
                }
            },
            .initialize => {
                const command = try rpc.parseCommandFromRequest(.initialize, message_buf, packet);
                const client_init_params = command.initialize;
                for (self.clients.items) |*c| {
                    if (client.state.id == c.id) {
                        c.active_display_state = try self.workspace.new(
                            state.TextBuffer.InitParams{
                                .contents = null,
                                .path = client_init_params.path,
                                .name = client_init_params.path,
                                .readonly = client_init_params.readonly,
                                .line_ending = client_init_params.line_ending,
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
                self.removeClient(client.state.id);
                if (self.watcher.fds.len == 1) {
                    self.deinit();
                    return error.ShouldQuit;
                }
            },
            else => @panic("Not implemented"),
        }
    }

    fn readConfig(ally: mem.Allocator) !Config {
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

pub const Application = struct {
    client: Client,
    /// In threaded mode we call `join` on `deinit`. In not threaded mode this field is `null`.
    server_thread: ?std.Thread = null,

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
        ally: mem.Allocator,
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
                    try startServer(ally, address);
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
                const server_thread = try std.Thread.spawn(.{}, startServer, .{ ally, address });
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

    fn startServer(ally: mem.Allocator, address: *net.Address) !void {
        var server = try Server.init(ally, address);
        server.initDynamic();
        errdefer server.deinit();
        try server.loop();
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        if (self.server_thread) |server_thread| {
            server_thread.join();
            self.server_thread = null;
        }
    }
};

pub const Client = struct {
    ally: mem.Allocator,
    ui: UI,
    server: ServerForClient,
    watcher: transport.Watcher,
    last_message_id: u32 = 0,

    const Self = @This();

    /// How Client sees the Server.
    pub const ServerForClient = struct {
        comms: transport.CommunicationResources,

        pub usingnamespace transport.CommunicationMixin(@This());
    };

    pub fn init(ally: mem.Allocator, ui: UI) Self {
        return Self{
            .ally = ally,
            .ui = ui,
            .watcher = transport.Watcher.init(ally),
            .server = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        const message = rpc.emptyNotification("quitted");
        self.server.send(message) catch {};
        // TEST: Check for race conditions.
        // std.time.sleep(std.time.ns_per_s * 1);
        self.watcher.deinit();
    }

    pub fn register(self: *Self, address: *net.Address) !void {
        defer self.ally.destroy(address);
        self.server = ServerForClient.initWithUnixSocket(
            try transport.connectToUnixSocket(address),
        );
        var request_buf: [transport.max_message_size]u8 = undefined;
        // Here we custom checking instead of waitForResponse because we expect `null` id which
        // is the single place where `null` in id is allowed for successful response.
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
                .line_ending = .unix,
            },
        );
        try self.server.send(message);
        try self.waitForResponse(message_id);
        try self.watcher.addConnectionSocket(self.server.comms.un_socket.socket, 0);
    }

    /// Main loop of the client, listens for keypresses and sends requests.
    pub fn loop(self: *Self) !void {
        // var packet_buf: [transport.max_packet_size]u8 = undefined;
        // var method_buf: [transport.max_method_size]u8 = undefined;
        // var message_buf: [transport.max_message_size]u8 = undefined;
        while (true) {
            if (try self.watcher.pollReadable(5)) |poll_result| {
                switch (poll_result) {
                    .success => |polled_data| {
                        switch (polled_data.ty) {
                            .listen_socket => unreachable,
                            .connection_socket => {
                                // TODO: process incoming notifications from the server.
                            },
                        }
                    },
                    .err => {
                        return error.ServerClosedConnection;
                    },
                }
            }
            if (self.ui.nextKey()) |key| {
                switch (key.code) {
                    .unicode_codepoint => {
                        if (key.isCtrl('c')) {
                            break;
                        }
                        // TODO: work with multiplier.
                        _ = try self.keypress(key, 1);
                    },
                    else => {
                        std.debug.print("Unrecognized key: {}\r\n", .{key});
                        return error.UnrecognizedKey;
                    },
                }
            }
        }
    }

    pub fn keypress(self: *Self, key: kisa.Key, multiplier: u32) !kisa.DrawData {
        const id = self.nextMessageId();
        const message = rpc.commandRequest(.keypress, id, .{ .key = key, .multiplier = multiplier });
        try self.server.send(message);
        return try self.receiveDrawData(id);
    }

    // It only returns `DrawData` for testing purposes, probably should be `void` instead.
    pub fn edit(self: *Client, path: []const u8) !kisa.DrawData {
        try self.openFile(path);
        return try self.redraw();
    }

    fn openFile(self: *Client, path: []const u8) !void {
        const id = self.nextMessageId();
        const message = rpc.commandRequest(.open_file, id, .{ .path = path });
        try self.server.send(message);
        try self.waitForResponse(id);
    }

    pub fn redraw(self: *Client) !kisa.DrawData {
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
        {
            const draw_data = try client.edit("/home/grfork/reps/kisa/kisarc.zzz");
            try testing.expectEqual(@as(usize, 1), draw_data.lines.len);
            try testing.expectEqual(@as(u32, 1), draw_data.lines[0].number);
            try testing.expectEqualStrings("hello", draw_data.lines[0].segments[0].contents);
        }
        {
            const draw_data = try client.keypress(kisa.Key.ascii('j'), 1);
            try testing.expectEqual(@as(usize, 1), draw_data.lines.len);
            try testing.expectEqual(@as(u32, 1), draw_data.lines[0].number);
            try testing.expectEqualStrings("hello", draw_data.lines[0].segments[0].contents);
        }
    }
}

test "fork/socket: start application forked via socket" {
    if (try Application.start(testing.allocator, .forked)) |*app| {
        defer app.deinit();
        var client = app.client;

        {
            const draw_data = try client.edit("/home/grfork/reps/kisa/kisarc.zzz");
            try testing.expectEqual(@as(usize, 1), draw_data.lines.len);
            try testing.expectEqual(@as(u32, 1), draw_data.lines[0].number);
            try testing.expectEqualStrings("hello", draw_data.lines[0].segments[0].contents);
        }
        {
            const draw_data = try client.keypress(kisa.Key.ascii('j'), 1);
            try testing.expectEqual(@as(usize, 1), draw_data.lines.len);
            try testing.expectEqual(@as(u32, 1), draw_data.lines[0].number);
            try testing.expectEqualStrings("hello", draw_data.lines[0].segments[0].contents);
        }
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const ally = gpa.allocator();

    var arg_it = std.process.args();
    _ = try arg_it.next(ally) orelse unreachable;
    const filename = blk: {
        if (arg_it.next(ally)) |file_name_delimited| {
            break :blk try file_name_delimited;
        } else {
            break :blk null;
        }
    };
    if (filename) |fname| {
        std.debug.print("Supplied filename: {s}\n", .{fname});
    } else {
        std.debug.print("No filename Supplied\n", .{});
    }
    std.debug.print("So far nothing in `main`, try `zig build test`\n", .{});
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

    fn nextByte(self: *Self) ?u8 {
        return self.in_stream.reader().readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            error.NotOpenForReading => return null,
            else => {
                std.debug.print("Unexpected error: {}\r\n", .{err});
                return 0;
            },
        };
    }

    pub fn nextKey(self: *Self) ?kisa.Key {
        if (self.nextByte()) |byte| {
            if (byte == 3) {
                return kisa.Key.ctrl('c');
            }
            return kisa.Key.ascii(byte);
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
            switch (os.linux.syscall3(.ioctl, fd, os.linux.T.IOCGWINSZ, @ptrToInt(&window_size))) {
                0 => {
                    rows.* = window_size.ws_row;
                    cols.* = window_size.ws_col;
                    return;
                },
                @enumToInt(os.E.INTR) => continue,
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
