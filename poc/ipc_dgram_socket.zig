const std = @import("std");
const os = std.os;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;

test "communication between Client and Server via dgram connection-less unix domain socket" {
    const socket = try os.socket(
        os.AF_UNIX,
        os.SOCK_DGRAM | os.SOCK_CLOEXEC,
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
        const message = try std.fmt.allocPrint(testing.allocator, "hello from client!\n", .{});
        defer testing.allocator.free(message);
        const bytes_sent = try os.sendto(socket, message, 0, sockaddr, addrlen);
        assert(message.len == bytes_sent);
    } else {
        // Server
        var buf: [256]u8 = undefined;
        const bytes_read = try os.recvfrom(socket, &buf, 0, null, null);
        std.debug.print("\nreceived on server: {s}\n", .{buf[0..bytes_read]});
    }
    std.time.sleep(std.time.ns_per_ms * 200);
}
