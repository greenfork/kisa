const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;
const testing = std.testing;
const assert = std.debug.assert;

// For testing slow and fast clients.
const delay_time = std.time.ns_per_ms * 0;

test "poll socket for listening and for reading" {
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
        var buf: [256]u8 = undefined;

        // Connect first client
        std.time.sleep(delay_time);
        const client_socket1 = try os.socket(
            os.AF_UNIX,
            os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
            os.PF_UNIX,
        );
        defer os.closeSocket(client_socket1);
        try os.connect(
            client_socket1,
            @ptrCast(*os.sockaddr, &address.un),
            @sizeOf(@TypeOf(address.un)),
        );

        // Write to first client and receive response
        {
            std.time.sleep(delay_time);
            const bytes_sent = try os.send(client_socket1, message, os.MSG_EOR);
            std.debug.print("client bytes sent: {d}\n", .{bytes_sent});
            assert(message.len == bytes_sent);
            const bytes_read = try os.recv(client_socket1, &buf, 0);
            std.debug.print(
                "received on client: {s}, {d} bytes\n",
                .{ buf[0..bytes_read], bytes_read },
            );
        }

        // Connect second client
        std.time.sleep(delay_time);
        const client_socket2 = try os.socket(
            os.AF_UNIX,
            os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
            os.PF_UNIX,
        );
        defer os.closeSocket(client_socket2);
        try os.connect(
            client_socket2,
            @ptrCast(*os.sockaddr, &address.un),
            @sizeOf(@TypeOf(address.un)),
        );

        // Write to second client and receive response
        {
            std.time.sleep(delay_time);
            const bytes_sent = try os.send(client_socket2, message, os.MSG_EOR);
            std.debug.print("client bytes sent: {d}\n", .{bytes_sent});
            assert(message.len == bytes_sent);
            const bytes_read = try os.recv(client_socket2, &buf, 0);
            std.debug.print(
                "received on client: {s}, {d} bytes\n",
                .{ buf[0..bytes_read], bytes_read },
            );
        }
    } else {
        // Server
        var buf: [256]u8 = undefined;
        const message = try std.fmt.allocPrint(testing.allocator, "hello from server!", .{});
        defer testing.allocator.free(message);
        const how_many_events_expected = 4;

        const socket = try os.socket(
            os.AF_UNIX,
            os.SOCK_SEQPACKET | os.SOCK_CLOEXEC,
            os.PF_UNIX,
        );
        try os.bind(socket, @ptrCast(*os.sockaddr, &address.un), @sizeOf(@TypeOf(address.un)));
        try os.listen(socket, 10);

        const FdType = enum { listen, read_write };

        var fds = std.ArrayList(os.pollfd).init(testing.allocator);
        defer {
            for (fds.items) |fd| os.closeSocket(fd.fd);
            fds.deinit();
        }
        var fd_types = std.ArrayList(FdType).init(testing.allocator);
        defer fd_types.deinit();

        try fds.append(os.pollfd{
            .fd = socket,
            .events = os.POLLIN,
            .revents = 0,
        });
        try fd_types.append(.listen);

        std.debug.print("\n", .{});
        var loop_counter: usize = 0;
        var event_counter: u8 = 0;
        while (true) : (loop_counter += 1) {
            std.debug.print("loop counter: {d}\n", .{loop_counter});

            const polled_events_count = try os.poll(fds.items, -1);
            if (polled_events_count > 0) {
                var current_event: u8 = 0;
                var processed_events_count: u8 = 0;
                while (current_event < fds.items.len) : (current_event += 1) {
                    if (fds.items[current_event].revents > 0) {
                        fds.items[current_event].revents = 0;
                        processed_events_count += 1;
                        event_counter += 1;

                        switch (fd_types.items[current_event]) {
                            .listen => {
                                const accepted_socket = try os.accept(
                                    socket,
                                    null,
                                    null,
                                    os.SOCK_CLOEXEC,
                                );
                                try fds.append(
                                    .{ .fd = accepted_socket, .events = os.POLLIN, .revents = 0 },
                                );
                                try fd_types.append(.read_write);
                            },
                            .read_write => {
                                const bytes_read = try os.recv(fds.items[current_event].fd, &buf, 0);
                                std.debug.print(
                                    "received on server: {s}, {d} bytes\n",
                                    .{ buf[0..bytes_read], bytes_read },
                                );
                                const bytes_sent = try os.send(
                                    fds.items[current_event].fd,
                                    message,
                                    os.MSG_EOR,
                                );
                                std.debug.print("server bytes sent: {d}\n", .{bytes_sent});
                                assert(message.len == bytes_sent);
                            },
                        }
                    }
                    if (processed_events_count == polled_events_count) break;
                }
            }
            if (event_counter == how_many_events_expected) break;
        }
    }
}
