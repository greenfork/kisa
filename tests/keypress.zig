const std = @import("std");
const io = std.io;
const os = std.os;

pub fn main() !void {
    // Get stdin and stdout
    const in_stream = io.getStdIn();
    const out_stream = io.getStdOut();

    // Save current termios
    const original_termios = try os.tcgetattr(in_stream.handle);

    // Set new termios
    var raw_termios = original_termios;
    raw_termios.iflag &=
        ~(@as(os.tcflag_t, os.BRKINT) | os.ICRNL | os.INPCK | os.ISTRIP | os.IXON);
    raw_termios.oflag &= ~(@as(os.tcflag_t, os.OPOST));
    raw_termios.cflag |= os.CS8;
    raw_termios.lflag &= ~(@as(os.tcflag_t, os.ECHO) | os.ICANON | os.IEXTEN | os.ISIG);
    raw_termios.cc[os.VMIN] = 0;
    raw_termios.cc[os.VTIME] = 1;
    try os.tcsetattr(in_stream.handle, os.TCSA.FLUSH, raw_termios);

    // Enter extended mode TMUX style
    try out_stream.writer().writeAll("\x1b[>4;1m");
    // Enter extended mode KITTY style
    // try out_stream.writer().writeAll("\x1b[>1u");

    // Read characters, press q to quit
    var buf = [_]u8{0} ** 8;
    var number_read = try in_stream.reader().read(buf[0..]);
    while (true) : (number_read = try in_stream.reader().read(buf[0..])) {
        if (number_read > 0) {
            switch (buf[0]) {
                'q' => break,
                else => {
                    std.debug.print("buf[0]: {x}\r\n", .{buf[0]});
                    std.debug.print("buf[1]: {x}\r\n", .{buf[1]});
                    std.debug.print("buf[2]: {x}\r\n", .{buf[2]});
                    std.debug.print("buf[3]: {x}\r\n", .{buf[3]});
                    std.debug.print("buf[4]: {x}\r\n", .{buf[4]});
                    std.debug.print("buf[5]: {x}\r\n", .{buf[5]});
                    std.debug.print("buf[6]: {x}\r\n", .{buf[6]});
                    std.debug.print("buf[7]: {x}\r\n", .{buf[7]});
                    std.debug.print("\r\n", .{});
                    buf[0] = 0;
                    buf[1] = 0;
                    buf[2] = 0;
                    buf[3] = 0;
                    buf[4] = 0;
                    buf[5] = 0;
                    buf[6] = 0;
                    buf[7] = 0;
                },
            }
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // Exit extended mode TMUX style
    try out_stream.writer().writeAll("\x1b[>4;0m");
    // Enter extended mode KITTY style
    // try out_stream.writer().writeAll("\x1b[<u");

    try os.tcsetattr(in_stream.handle, os.TCSA.FLUSH, original_termios);
}
