const std = @import("std");
const os = std.os;

// Communication from Client to Server.
pub fn main() !void {
    var fds = try os.pipe();
    var read_end = fds[0];
    var write_end = fds[1];
    const pid = try os.fork();
    if (pid == 0) {
        // Client writes
        os.close(read_end);
        var write_stream = std.fs.File{
            .handle = write_end,
            .capable_io_mode = .blocking,
            .intended_io_mode = .blocking,
        };
        try write_stream.writer().writeAll("Hello!");
    } else {
        // Server reads
        os.close(write_end);
        var read_stream = std.fs.File{
            .handle = read_end,
            .capable_io_mode = .blocking,
            .intended_io_mode = .blocking,
        };
        var buf = [_]u8{0} ** 6;
        const read_bytes = try read_stream.reader().read(buf[0..]);
        std.debug.print("read from buf: {s}\n", .{buf[0..read_bytes]});
    }
}
