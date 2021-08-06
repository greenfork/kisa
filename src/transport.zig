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

pub fn bindUnixSocket(address: *net.Address) !os.socket_t {
    const socket = try os.socket(
        os.AF_UNIX,
        os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
        os.PF_UNIX,
    );
    errdefer os.closeSocket(socket);
    try os.bind(socket, @ptrCast(*os.sockaddr, &address.un), @sizeOf(@TypeOf(address.un)));
    try os.listen(socket, 10);
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
        os.connect(
            socket,
            @ptrCast(*os.sockaddr, &address.un),
            @sizeOf(@TypeOf(address.un)),
        ) catch |err| switch (err) {
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

test "transport: communication via un_socket" {
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
