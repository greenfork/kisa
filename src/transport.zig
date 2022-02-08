//! Communication of Client and Server, also communication of operating system and this application.
const std = @import("std");
const os = std.os;
const net = std.net;
const testing = std.testing;
const assert = std.debug.assert;
const known_folders = @import("known-folders");

pub const known_folders_config = .{
    .xdg_on_mac = true,
};

pub const TransportKind = enum {
    un_socket,
};

pub const max_packet_size: usize = 1024 * 8;
pub const max_method_size: usize = 1024;
pub const max_message_size: usize = max_packet_size;
const max_connect_retries = 50;
const connect_retry_delay = std.time.ns_per_ms * 5;
const listen_socket_backlog = 10;

pub fn bindUnixSocket(address: *net.Address) !os.socket_t {
    const socket = try os.socket(
        os.AF.UNIX,
        os.SOCK.STREAM | os.SOCK.CLOEXEC,
        // Should be PF.UNIX but it is only available as os.linux.PF.UNIX which is not
        // cross-compatible across OS. But the implementation says that PF and AF values
        // are same in this case since PF is redundant now and was a design precaution/mistake
        // made in the past.
        os.AF.UNIX,
    );
    errdefer os.closeSocket(socket);
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, listen_socket_backlog);
    return socket;
}

pub fn connectToUnixSocket(address: *net.Address) !os.socket_t {
    const socket = try os.socket(
        os.AF.UNIX,
        os.SOCK.STREAM | os.SOCK.CLOEXEC,
        os.AF.UNIX,
    );
    errdefer os.closeSocket(socket);
    var connect_retries: u8 = max_connect_retries;
    while (true) {
        os.connect(socket, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => {
                // If the server is not yet listening, wait a bit.
                if (connect_retries == 0) return err;
                std.time.sleep(connect_retry_delay);
                connect_retries -= 1;
                continue;
            },
            else => return err,
        };
        break;
    }
    return socket;
}

/// Caller owns the memory.
pub fn pathForUnixSocket(ally: std.mem.Allocator) ![]u8 {
    const runtime_dir = (try known_folders.getPath(
        ally,
        .runtime,
    )) orelse (try known_folders.getPath(
        ally,
        .app_menu,
    )) orelse return error.NoRuntimeDirectory;
    defer ally.free(runtime_dir);
    const subpath = "kisa";
    var path_builder = std.ArrayList(u8).init(ally);
    errdefer path_builder.deinit();
    try path_builder.appendSlice(runtime_dir);
    try path_builder.append(std.fs.path.sep);
    try path_builder.appendSlice(subpath);
    std.fs.makeDirAbsolute(path_builder.items) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const filename = try std.fmt.allocPrint(ally, "{d}", .{os.linux.getpid()});
    defer ally.free(filename);
    try path_builder.append(std.fs.path.sep);
    try path_builder.appendSlice(filename);
    std.fs.deleteFileAbsolute(path_builder.items) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return path_builder.toOwnedSlice();
}

/// Caller owns the memory.
pub fn addressForUnixSocket(ally: std.mem.Allocator, path: []const u8) !*net.Address {
    const address = try ally.create(net.Address);
    errdefer ally.destroy(address);
    address.* = try net.Address.initUnix(path);
    return address;
}

pub const CommunicationResources = union(TransportKind) {
    un_socket: struct {
        socket: os.socket_t,
        buffered_reader: SocketBufferedReader,
    },

    const Self = @This();
    const SocketReader = std.io.Reader(os.socket_t, os.RecvFromError, socketRead);
    fn socketRead(socket: os.socket_t, buffer: []u8) os.RecvFromError!usize {
        return try os.recv(socket, buffer, 0);
    }
    const SocketBufferedReader = std.io.BufferedReader(max_packet_size, SocketReader);

    pub fn initWithUnixSocket(socket: os.socket_t) Self {
        var socket_stream = SocketReader{ .context = socket };
        var buffered_reader = SocketBufferedReader{ .unbuffered_reader = socket_stream };
        return Self{ .un_socket = .{
            .socket = socket,
            .buffered_reader = buffered_reader,
        } };
    }
};

/// `CommunicationContainer` must be a container which has `comms` field
/// of type `CommunicationResources`.
pub fn CommunicationMixin(comptime CommunicationContainer: type) type {
    return struct {
        const Self = CommunicationContainer;
        /// ASCII: end of transmission block. (isn't this the perfect character to send?)
        const packet_delimiter = 0x17;

        pub fn initWithUnixSocket(socket: os.socket_t) Self {
            return Self{ .comms = CommunicationResources.initWithUnixSocket(socket) };
        }

        pub fn deinitComms(self: Self) void {
            switch (self.comms) {
                .un_socket => |s| {
                    os.closeSocket(s.socket);
                },
            }
        }

        // TODO: allow the caller to pass `packet_buf`.
        /// Sends a message, `message` must implement `generate` receiving a buffer and putting
        /// []u8 contents into it.
        pub fn send(self: Self, message: anytype) !void {
            var packet_buf: [max_packet_size]u8 = undefined;
            const packet = try message.generate(&packet_buf);
            packet_buf[packet.len] = packet_delimiter;
            try self.sendPacket(packet_buf[0 .. packet.len + 1]);
        }

        pub fn sendPacket(self: Self, packet: []const u8) !void {
            switch (self.comms) {
                .un_socket => |s| {
                    const bytes_sent = try os.send(s.socket, packet, 0);
                    assert(packet.len == bytes_sent);
                },
            }
        }

        /// Reads a message of type `Message` with memory stored inside `out_buf`, `Message` must
        /// implement `parse` taking a buffer and a string, returning `Message` object.
        pub fn recv(self: *Self, comptime Message: type, out_buf: []u8) !?Message {
            var packet_buf: [max_packet_size]u8 = undefined;
            if (try self.readPacket(&packet_buf)) |packet| {
                return try Message.parse(out_buf, packet);
            } else {
                return null;
            }
        }

        /// Returns the slice with the length of a received packet.
        pub fn readPacket(self: *Self, buf: []u8) !?[]u8 {
            switch (self.comms) {
                .un_socket => |*s| {
                    var stream = s.buffered_reader.reader();
                    var read_buf = stream.readUntilDelimiter(buf, packet_delimiter) catch |e| switch (e) {
                        error.EndOfStream => return null,
                        else => return e,
                    };
                    if (read_buf.len == 0) return null;
                    if (buf.len == read_buf.len) return error.MessageTooBig;
                    return read_buf;
                },
            }
        }
    };
}

pub const FdType = enum {
    /// Listens for incoming client connections to the server.
    listen_socket,
    /// Used for communication between client and server.
    connection_socket,
};

pub const WatcherFd = struct {
    /// Native to the OS structure which is used for polling.
    pollfd: os.pollfd,
    /// Metadata for identifying the type of a file descriptor.
    ty: FdType,
    /// External identifier which is interpreted by the user of this API.
    id: u32,
};

pub const Watcher = struct {
    ally: std.mem.Allocator,
    /// Array of file descriptor data. Must not be modified directly, only with provided API.
    fds: std.MultiArrayList(WatcherFd) = std.MultiArrayList(WatcherFd){},
    /// `poll` call can return several events at a time, this is their total count per call.
    pending_events_count: usize = 0,
    /// When `poll` returns several events, this cursor is used for subsequent searches
    /// inside `pollfd` array.
    pending_events_cursor: usize = 0,

    const Self = @This();
    const Result = struct { fd: os.fd_t, id: u32, ty: FdType, fd_index: usize };
    const PollResult = union(enum) {
        success: Result,
        err: struct { id: u32 },
    };

    pub fn init(ally: std.mem.Allocator) Self {
        return Self{ .ally = ally };
    }

    pub fn deinit(self: *Self) void {
        for (self.fds.items(.pollfd)) |pollfd| os.close(pollfd.fd);
        self.fds.deinit(self.ally);
    }

    /// Adds listen socket which is used for listening for other sockets' connections.
    pub fn addListenSocket(self: *Self, fd: os.fd_t, id: u32) !void {
        try self.addFd(fd, os.POLL.IN, .listen_socket, id);
    }

    /// Adds connection socket which is used for communication between server and client.
    pub fn addConnectionSocket(self: *Self, fd: os.fd_t, id: u32) !void {
        try self.addFd(fd, os.POLL.IN, .connection_socket, id);
    }

    pub fn findFileDescriptor(self: Self, id: u32) ?Result {
        for (self.fds.items(.id)) |fds_id, idx| {
            if (fds_id == id) {
                const pollfds = self.fds.items(.pollfd);
                const tys = self.fds.items(.ty);
                return Result{
                    .fd = pollfds[idx].fd,
                    .id = id,
                    .ty = tys[idx],
                    .fd_index = idx,
                };
            }
        }
        return null;
    }

    /// Removes any file descriptor with `id`, `id` must exist in the current
    /// array of ids.
    pub fn removeFileDescriptor(self: *Self, id: u32) void {
        for (self.fds.items(.id)) |fds_id, idx| {
            if (fds_id == id) {
                self.removeFd(idx);
                return;
            }
        }
    }

    fn addFd(self: *Self, fd: os.fd_t, events: i16, ty: FdType, id: u32) !void {
        // Only add ready-for-reading notifications with current assumptions of `pollReadable`.
        assert(events == os.POLL.IN);
        // Ensure the `id` is unique across all elements.
        for (self.fds.items(.id)) |existing_id| assert(id != existing_id);

        try self.fds.append(self.ally, .{
            .pollfd = os.pollfd{
                .fd = fd,
                .events = events,
                .revents = 0,
            },
            .ty = ty,
            .id = id,
        });
    }

    fn removeFd(self: *Self, index: usize) void {
        os.close(self.fds.items(.pollfd)[index].fd);
        self.fds.swapRemove(index);
    }

    /// Returns a readable file descriptor or `null` if timeout has expired. If timeout is -1,
    /// always returns non-null result. Assumes that we don't have any other descriptors
    /// other than readable and that this will block if no readable file descriptors are
    /// available.
    pub fn pollReadable(self: *Self, timeout: i32) !?PollResult {
        if ((try self.poll(timeout)) == 0) return null;

        const pollfds = self.fds.items(.pollfd);
        const ids = self.fds.items(.id);
        const tys = self.fds.items(.ty);
        while (self.pending_events_cursor < pollfds.len) : (self.pending_events_cursor += 1) {
            const revents = pollfds[self.pending_events_cursor].revents;
            if (revents != 0) {
                self.pending_events_count -= 1;
                if (revents & (os.POLL.ERR | os.POLL.HUP | os.POLL.NVAL) != 0) {
                    // `pollfd` is removed by swapping current one with the last one, so the cursor
                    // stays the same.
                    const result = PollResult{ .err = .{
                        .id = ids[self.pending_events_cursor],
                    } };
                    self.removeFd(self.pending_events_cursor);
                    return result;
                } else if (revents & os.POLL.IN != 0) {
                    const result = PollResult{ .success = .{
                        .fd = pollfds[self.pending_events_cursor].fd,
                        .id = ids[self.pending_events_cursor],
                        .ty = tys[self.pending_events_cursor],
                        .fd_index = self.pending_events_cursor,
                    } };
                    self.pending_events_cursor += 1;
                    return result;
                }
            }
        }
        unreachable;
    }

    /// Fills current `fds` array with result events which can be inspected.
    fn poll(self: *Self, timeout: i32) !usize {
        if (self.pending_events_count == 0) {
            self.pending_events_count = try os.poll(self.fds.items(.pollfd), timeout);
            self.pending_events_cursor = 0;
        }
        return self.pending_events_count;
    }
};

const MyContainer = struct {
    comms: CommunicationResources,
    usingnamespace CommunicationMixin(@This());
};
const MyMessage = struct {
    contents: []u8,

    const Self = @This();

    fn generate(message: Self, out_buf: []u8) ![]u8 {
        const str = message.contents;
        std.mem.copy(u8, out_buf, str);
        return out_buf[0..str.len];
    }
    fn parse(out_buf: []u8, string: []const u8) !Self {
        const str = string;
        std.mem.copy(u8, out_buf, str);
        return Self{ .contents = out_buf[0..str.len] };
    }
};

test "transport/fork1: communication via un_socket" {
    const path = try pathForUnixSocket(testing.allocator);
    defer testing.allocator.free(path);
    const address = try addressForUnixSocket(testing.allocator, path);
    defer testing.allocator.destroy(address);
    const str1 = "generated string1";
    const str2 = "gerted stng2";

    const pid = try os.fork();
    if (pid == 0) {
        const listen_socket = try bindUnixSocket(address);
        const accepted_socket = try os.accept(listen_socket, null, null, 0);
        var server = MyContainer.initWithUnixSocket(accepted_socket);
        var buf: [256]u8 = undefined;
        {
            const message = try server.recv(MyMessage, &buf);
            std.debug.assert(message != null);
            try testing.expectEqualStrings(str1, message.?.contents);
        }
        {
            const message = try server.recv(MyMessage, &buf);
            std.debug.assert(message != null);
            try testing.expectEqualStrings(str2, message.?.contents);
        }
    } else {
        const client = MyContainer.initWithUnixSocket(try connectToUnixSocket(address));
        var buf: [200]u8 = undefined;
        // Attempt to send 2 packets simultaneously.
        const str = str1 ++ "\x17" ++ str2;
        std.mem.copy(u8, &buf, str);
        const message = MyMessage{ .contents = buf[0..str.len] };
        try client.send(message);
    }
}

test "transport/fork2: client and server both poll events with watcher" {
    const path = try pathForUnixSocket(testing.allocator);
    defer testing.allocator.free(path);
    const address = try addressForUnixSocket(testing.allocator, path);
    defer testing.allocator.destroy(address);
    const client_message = "hello from client";

    const pid = try os.fork();
    if (pid == 0) {
        // Server
        const listen_socket = try bindUnixSocket(address);
        var watcher = Watcher.init(testing.allocator);
        defer watcher.deinit();
        try watcher.addListenSocket(listen_socket, 0);
        var cnt: u8 = 3;
        while (cnt > 0) : (cnt -= 1) {
            switch ((try watcher.pollReadable(-1)).?) {
                .success => |polled_data| {
                    switch (polled_data.ty) {
                        .listen_socket => {
                            const accepted_socket = try os.accept(polled_data.fd, null, null, 0);
                            try watcher.addConnectionSocket(accepted_socket, 1);
                            const bytes_sent = try os.send(accepted_socket, "1", 0);
                            try testing.expectEqual(@as(usize, 1), bytes_sent);
                        },
                        .connection_socket => {
                            var buf: [256]u8 = undefined;
                            const bytes_read = try os.recv(polled_data.fd, &buf, 0);
                            if (bytes_read != 0) {
                                try testing.expectEqualStrings(client_message, buf[0..bytes_read]);
                            } else {
                                // This should have been handled by POLLHUP event and union is `err`.
                                unreachable;
                            }
                        },
                    }
                },
                .err => {},
            }
        }
    } else {
        // Client
        const message = try std.fmt.allocPrint(testing.allocator, client_message, .{});
        defer testing.allocator.free(message);
        const socket = try connectToUnixSocket(address);
        var watcher = Watcher.init(testing.allocator);
        defer watcher.deinit();
        try watcher.addConnectionSocket(socket, 0);
        switch ((try watcher.pollReadable(-1)).?) {
            .success => |polled_data| {
                var buf: [256]u8 = undefined;
                const bytes_read = try os.recv(polled_data.fd, &buf, 0);
                try testing.expectEqualStrings("1", buf[0..bytes_read]);
            },
            .err => unreachable,
        }
        const bytes_sent = try os.send(socket, message, 0);
        try testing.expectEqual(message.len, bytes_sent);
    }
}
