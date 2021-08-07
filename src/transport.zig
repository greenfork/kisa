const std = @import("std");
const os = std.os;
const net = std.net;
const testing = std.testing;
const known_folders = @import("known-folders");

pub const known_folders_config = .{
    .xdg_on_mac = true,
};

pub const TransportKind = enum {
    un_socket,
};

const max_connect_retries = 50;
const connect_retry_delay = std.time.ns_per_ms * 5;
const listen_socket_backlog = 10;

pub fn bindUnixSocket(address: *net.Address) !os.socket_t {
    const socket = try os.socket(
        os.AF_UNIX,
        os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
        os.PF_UNIX,
    );
    errdefer os.closeSocket(socket);
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, listen_socket_backlog);
    return socket;
}

pub fn connectToUnixSocket(address: *net.Address) !os.socket_t {
    const socket = try os.socket(
        os.AF_UNIX,
        os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
        os.PF_UNIX,
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
pub fn pathForUnixSocket(ally: *std.mem.Allocator) ![]u8 {
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
pub fn addressForUnixSocket(ally: *std.mem.Allocator, path: []const u8) !*net.Address {
    const address = try ally.create(net.Address);
    errdefer ally.destroy(address);
    address.* = try net.Address.initUnix(path);
    return address;
}

pub const CommunicationResources = union(TransportKind) {
    un_socket: struct {
        socket: os.socket_t,
    },
};

/// `CommunicationContainer` must be a container which has `comms` field
/// of type `CommunicationResources`.
pub fn CommunicationMixin(comptime CommunicationContainer: type) type {
    return struct {
        const Self = CommunicationContainer;
        pub const max_packet_size: usize = 1024 * 16;
        pub const max_method_size: usize = 1024;
        pub const max_message_size: usize = max_packet_size;

        pub fn initWithUnixSocket(socket: os.socket_t) Self {
            return Self{
                .comms = CommunicationResources{ .un_socket = .{ .socket = socket } },
            };
        }

        pub fn deinitComms(self: Self) void {
            switch (self.comms) {
                .un_socket => |s| {
                    os.closeSocket(s.socket);
                },
            }
        }

        /// Sends a message, `message` must implement `generate` receiving a buffer and putting
        /// []u8 content into it.
        pub fn send(self: Self, message: anytype) !void {
            switch (self.comms) {
                .un_socket => |s| {
                    var packet_buf: [max_packet_size]u8 = undefined;
                    const packet = try message.generate(&packet_buf);
                    const bytes_sent = try os.send(s.socket, packet, 0);
                    std.debug.assert(packet.len == bytes_sent);
                },
            }
        }

        /// Reads a message of type `Message` with memory stored inside `out_buf`, `Message` must
        /// implement `parse` taking a buffer and a string, returning `Message` object.
        pub fn recv(self: Self, comptime Message: type, out_buf: []u8) !?Message {
            var packet_buf: [max_packet_size]u8 = undefined;
            if (try self.readPacket(&packet_buf)) |packet| {
                return try Message.parse(out_buf, packet);
            } else {
                return null;
            }
        }

        /// Returns the slice with the length of a received packet.
        pub fn readPacket(self: Self, buf: []u8) !?[]u8 {
            switch (self.comms) {
                .un_socket => |s| {
                    const bytes_read = try os.recv(s.socket, buf, 0);
                    if (bytes_read == 0) return null;
                    if (buf.len == bytes_read) return error.MessageTooBig;
                    return buf[0..bytes_read];
                },
            }
        }
    };
}

pub const FdType = enum {
    listen_socket,
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
    ally: *std.mem.Allocator,
    fds: std.MultiArrayList(WatcherFd) = std.MultiArrayList(WatcherFd){},
    /// `poll` call can return several events at a time, this is their total count per call.
    pending_events_count: usize = 0,
    /// When `poll` returns several events, this cursor is used for subsequent searches
    /// inside `pollfd` array.
    pending_events_cursor: usize = 0,

    const Self = @This();
    const PollResult = union(enum) {
        success: struct { fd: os.fd_t, id: u32, ty: FdType, fd_index: usize },
        err: struct { id: u32 },
    };

    pub fn init(ally: *std.mem.Allocator) Self {
        return Self{ .ally = ally };
    }

    pub fn deinit(self: *Self) void {
        for (self.fds.items(.pollfd)) |pollfd| os.close(pollfd.fd);
        self.fds.deinit(self.ally);
    }

    pub fn addFd(self: *Self, fd: os.fd_t, events: i16, ty: FdType, id: u32) !void {
        std.debug.assert(events == os.POLLIN);
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

    pub fn removeFd(self: *Self, index: usize) void {
        std.debug.assert(index < self.fds.len);
        os.close(self.fds.items(.pollfd)[index].fd);
        self.fds.swapRemove(index);
    }

    /// Returns a readable file descriptor. Assumes that we don't have any other descriptors
    /// other than readable and that this will block if no readable file descriptors are
    /// available.
    pub fn pollReadable(self: *Self) !PollResult {
        try self.poll();

        const pollfds = self.fds.items(.pollfd);
        const ids = self.fds.items(.id);
        const tys = self.fds.items(.ty);
        while (self.pending_events_cursor < pollfds.len) : (self.pending_events_cursor += 1) {
            const revents = pollfds[self.pending_events_cursor].revents;
            if (revents != 0) {
                self.pending_events_count -= 1;
                if (revents & (os.POLLERR | os.POLLHUP | os.POLLNVAL) != 0) {
                    // `pollfd` is removed by swapping current one with the last one, so the cursor
                    // stays the same.
                    const result = PollResult{ .err = .{
                        .id = ids[self.pending_events_cursor],
                    } };
                    self.removeFd(self.pending_events_cursor);
                    return result;
                } else if (revents & os.POLLIN != 0) {
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
    fn poll(self: *Self) !void {
        if (self.pending_events_count == 0) {
            self.pending_events_count = try os.poll(self.fds.items(.pollfd), -1);
            std.debug.assert(self.pending_events_count > 0);
            self.pending_events_cursor = 0;
        }
    }
};

const MyContainer = struct {
    comms: CommunicationResources,
    usingnamespace CommunicationMixin(@This());
};
const MyMessage = struct {
    content: []u8,

    const Self = @This();

    fn generate(message: anytype, out_buf: []u8) ![]u8 {
        _ = message;
        const str = "generated message";
        std.mem.copy(u8, out_buf, str);
        return out_buf[0..str.len];
    }
    fn parse(out_buf: []u8, string: []const u8) !Self {
        _ = string;
        const str = "parsed message";
        std.mem.copy(u8, out_buf, str);
        return Self{ .content = out_buf[0..str.len] };
    }
};

test "transport/fork1: communication via un_socket" {
    const path = try pathForUnixSocket(testing.allocator);
    defer testing.allocator.free(path);
    const address = try addressForUnixSocket(testing.allocator, path);
    defer testing.allocator.destroy(address);

    const pid = try os.fork();
    if (pid == 0) {
        const listen_socket = try bindUnixSocket(address);
        const accepted_socket = try os.accept(listen_socket, null, null, 0);
        const server = MyContainer.initWithUnixSocket(accepted_socket);
        var buf: [256]u8 = undefined;
        const message = try server.recv(MyMessage, &buf);
        std.debug.assert(message != null);
    } else {
        const client = MyContainer.initWithUnixSocket(try connectToUnixSocket(address));
        const message = MyMessage{ .content = undefined };
        try client.send(message);
    }
}

test "transport/fork2: polling with watcher" {
    const path = try pathForUnixSocket(testing.allocator);
    defer testing.allocator.free(path);
    const address = try addressForUnixSocket(testing.allocator, path);
    defer testing.allocator.destroy(address);
    const client_message = "hello from client";

    const pid = try os.fork();
    if (pid == 0) {
        var watcher = Watcher.init(testing.allocator);
        defer watcher.deinit();
        const listen_socket = try bindUnixSocket(address);
        try watcher.addFd(listen_socket, os.POLLIN, .listen_socket, 0);
        var cnt: u8 = 3;
        while (cnt > 0) : (cnt -= 1) {
            switch (try watcher.pollReadable()) {
                .success => |polled_data| {
                    switch (polled_data.ty) {
                        .listen_socket => {
                            const accepted_socket = try os.accept(polled_data.fd, null, null, 0);
                            try watcher.addFd(accepted_socket, os.POLLIN, .connection_socket, 0);
                        },
                        .connection_socket => {
                            var buf: [256]u8 = undefined;
                            const bytes_read = try os.recv(polled_data.fd, &buf, 0);
                            if (bytes_read != 0) {
                                try testing.expectEqualStrings(client_message, buf[0..bytes_read]);
                            } else {
                                // This should have been handled by POLLHUP event.
                                unreachable;
                            }
                        },
                    }
                },
                .err => {},
            }
        }
    } else {
        const message = try std.fmt.allocPrint(testing.allocator, client_message, .{});
        defer testing.allocator.free(message);
        const socket = try connectToUnixSocket(address);
        defer os.closeSocket(socket);
        _ = try os.send(socket, message, 0);
    }
}