// As long as socket buffer is large enough, the operation is non-blocking. On my
// linux machine unix socket's defalt write buffer size is 208 KB which is more than enough.

const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;
const testing = std.testing;
const assert = std.debug.assert;

// For testing slow and fast clients.
const delay_time = std.time.ns_per_ms * 0;
var bytes_sent: usize = 0;
var bytes_read: usize = 0;

test "socket sends small data amounts without blocking" {
    const socket_path = try std.fmt.allocPrint(testing.allocator, "/tmp/poll.socket", .{});
    defer testing.allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const address = try testing.allocator.create(net.Address);
    defer testing.allocator.destroy(address);
    address.* = try net.Address.initUnix(socket_path);

    const pid = try os.fork();
    if (pid == 0) {
        // Client
        const message = try std.fmt.allocPrint(testing.allocator, "hello from client!", .{});
        defer testing.allocator.free(message);
        var buf: [6000]u8 = undefined;

        std.time.sleep(delay_time);
        const client_socket = try os.socket(
            os.AF_UNIX,
            os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
            os.PF_UNIX,
        );
        defer os.closeSocket(client_socket);
        try os.connect(
            client_socket,
            @ptrCast(*os.sockaddr, &address.un),
            @sizeOf(@TypeOf(address.un)),
        );

        bytes_read = try os.recv(client_socket, &buf, 0);
        std.debug.print("received on client: {d} bytes\n", .{bytes_read});
        std.time.sleep(delay_time);

        bytes_read = try os.recv(client_socket, &buf, 0);
        std.debug.print("received on client: {d} bytes\n", .{bytes_read});
        std.time.sleep(delay_time);

        bytes_read = try os.recv(client_socket, &buf, 0);
        std.debug.print("received on client: {d} bytes\n", .{bytes_read});
        std.time.sleep(delay_time);
    } else {
        // Server
        const a5000_const = [_]u8{'a'} ** 5000;
        const a5000 = try std.fmt.allocPrint(testing.allocator, &a5000_const, .{});
        defer testing.allocator.free(a5000);

        const socket = try os.socket(
            os.AF_UNIX,
            os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
            os.PF_UNIX,
        );
        try os.bind(socket, @ptrCast(*os.sockaddr, &address.un), @sizeOf(@TypeOf(address.un)));
        try os.listen(socket, 10);
        const client_socket = try os.accept(socket, null, null, os.SOCK_CLOEXEC);
        defer os.closeSocket(client_socket);

        const socket_abstr = std.x.os.Socket.from(client_socket);
        std.debug.print(
            "\nInitial socket write buffer size: {d}\n",
            .{try socket_abstr.getWriteBufferSize()},
        );

        bytes_sent = try os.send(client_socket, a5000, os.MSG_EOR | os.MSG_DONTWAIT);
        assert(a5000.len == bytes_sent);

        try socket_abstr.setWriteBufferSize(5000);

        bytes_sent = try os.send(client_socket, a5000, os.MSG_EOR | os.MSG_DONTWAIT);
        assert(a5000.len == bytes_sent);

        try socket_abstr.setWriteBufferSize(4000);

        try std.testing.expectError(
            error.WouldBlock,
            os.send(client_socket, a5000, os.MSG_EOR | os.MSG_DONTWAIT),
        );
    }
}
