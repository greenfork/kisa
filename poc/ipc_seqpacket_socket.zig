const std = @import("std");
const os = std.os;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

test "communication between Client and Server via dgram connection-less unix domain socket" {
    const socket = try os.socket(
        os.AF_UNIX,
        os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
        os.PF_UNIX,
    );
    defer os.closeSocket(socket);

    const runtime_dir = try std.fmt.allocPrint(testing.allocator, "/var/run/user/1000", .{});
    const subpath = "/kisa";
    var path_builder = std.ArrayList(u8).fromOwnedSlice(testing.allocator, runtime_dir);
    defer path_builder.deinit();
    try path_builder.appendSlice(subpath);
    std.fs.makeDirAbsolute(path_builder.items) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const filename = try std.fmt.allocPrint(testing.allocator, "{d}", .{os.linux.getpid()});
    defer testing.allocator.free(filename);
    try path_builder.append('/');
    try path_builder.appendSlice(filename);
    std.fs.deleteFileAbsolute(path_builder.items) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const addr = try testing.allocator.create(os.sockaddr_un);
    defer testing.allocator.destroy(addr);
    addr.* = os.sockaddr_un{ .path = undefined };
    mem.copy(u8, &addr.path, path_builder.items);
    addr.path[path_builder.items.len] = 0; // null-terminated string

    const sockaddr = @ptrCast(*os.sockaddr, addr);
    var addrlen: os.socklen_t = @sizeOf(@TypeOf(addr.*));
    try os.bind(socket, sockaddr, addrlen);

    const pid = try os.fork();
    if (pid == 0) {
        // Client
        const client_socket = try os.socket(
            os.AF_UNIX,
            os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
            os.PF_UNIX,
        );
        defer os.closeSocket(client_socket);
        const message = try std.fmt.allocPrint(testing.allocator, "hello from client!", .{});
        defer testing.allocator.free(message);
        var client_connected = false;
        var connect_attempts: u8 = 25;
        while (!client_connected) {
            os.connect(client_socket, sockaddr, addrlen) catch |err| switch (err) {
                error.ConnectionRefused => {
                    // If server is not yet listening, wait a bit.
                    if (connect_attempts == 0) return err;
                    std.time.sleep(std.time.ns_per_ms * 10);
                    connect_attempts -= 1;
                    continue;
                },
                else => return err,
            };
            client_connected = true;
        }
        var bytes_sent = try os.send(client_socket, message, os.MSG_EOR);
        assert(message.len == bytes_sent);
        bytes_sent = try os.send(client_socket, message, os.MSG_EOR);
        assert(message.len == bytes_sent);
        var buf: [256]u8 = undefined;
        var bytes_read = try os.recv(client_socket, &buf, 0);
        std.debug.print("\nreceived on client: {s}\n", .{buf[0..bytes_read]});
    } else {
        // Server
        std.time.sleep(std.time.ns_per_ms * 200);
        try os.listen(socket, 10);
        const accepted_socket = try os.accept(socket, null, null, os.SOCK_CLOEXEC);
        defer os.closeSocket(accepted_socket);

        var buf: [256]u8 = undefined;
        var counter: u8 = 0;
        while (counter < 2) : (counter += 1) {
            const bytes_read = try os.recv(accepted_socket, &buf, 0);
            std.debug.print("\n{d}: received on server: {s}\n", .{ counter, buf[0..bytes_read] });
        }
        const message = try std.fmt.allocPrint(testing.allocator, "hello from server!", .{});
        defer testing.allocator.free(message);
        var bytes_sent = try os.send(accepted_socket, message, os.MSG_EOR);
        assert(message.len == bytes_sent);
    }
}
