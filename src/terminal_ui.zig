const std = @import("std");
const testing = std.testing;
const kisa = @import("kisa");

const TerminalUI = @This();
const writer_buffer_size = 4096;
const WriterCtx = std.io.BufferedWriter(
    writer_buffer_size,
    std.io.Writer(std.fs.File, std.fs.File.WriteError, std.fs.File.write),
);
pub const Dimensions = struct {
    width: u16,
    height: u16,
};
const Support = struct {
    ansi_escape_codes: bool,
};
const esc = "\x1B";
const csi = esc ++ "[";
const style_reset = csi ++ "0m";
const style_bold = csi ++ "1m";
const style_dim = csi ++ "2m";
const style_italic = csi ++ "3m";
const style_underline = csi ++ "4m";
const style_reverse = csi ++ "7m";
const style_strikethrough = csi ++ "9m";
const clear_all = csi ++ "2J";
const cursor_hide = csi ++ "?25l";
const cursor_show = csi ++ "?25h";

original_termios: std.os.termios,
dimensions: Dimensions,
in: std.fs.File,
out: std.fs.File,
writer_ctx: WriterCtx,
support: Support,

pub fn init(in: std.fs.File, out: std.fs.File) !TerminalUI {
    if (!in.isTty()) return error.NotTTY;

    var original_termios = try std.os.tcgetattr(in.handle);
    var termios = original_termios;

    // Black magic, see https://github.com/antirez/kilo
    termios.iflag &= ~(std.os.linux.BRKINT | std.os.linux.ICRNL | std.os.linux.INPCK |
        std.os.linux.ISTRIP | std.os.linux.IXON);
    termios.oflag &= ~(std.os.linux.OPOST);
    termios.cflag |= (std.os.linux.CS8);
    termios.lflag &= ~(std.os.linux.ECHO | std.os.linux.ICANON | std.os.linux.IEXTEN |
        std.os.linux.ISIG);
    // Polling read, doesn't block.
    termios.cc[std.os.linux.V.MIN] = 0;
    // VTIME tenths of a second elapses between bytes. Can be important for slow terminals,
    // libtermkey (neovim) uses 50ms, which matters for example when pressing Alt key which
    // sends several bytes but the very first one is Esc, so it is necessary to wait enough
    // time for disambiguation. This setting alone can be not enough.
    termios.cc[std.os.linux.V.TIME] = 1;

    try std.os.tcsetattr(in.handle, .FLUSH, termios);
    return TerminalUI{
        .original_termios = original_termios,
        .dimensions = try getWindowSize(in.handle),
        .in = in,
        .out = out,
        .writer_ctx = .{ .unbuffered_writer = out.writer() },
        .support = .{ .ansi_escape_codes = out.supportsAnsiEscapeCodes() },
    };
}

fn getWindowSize(handle: std.os.fd_t) !Dimensions {
    var window_size: std.os.linux.winsize = undefined;
    const err = std.os.linux.ioctl(handle, std.os.linux.T.IOCGWINSZ, @ptrToInt(&window_size));
    if (std.os.errno(err) != .SUCCESS) {
        return error.IoctlError;
    }
    return Dimensions{
        .width = window_size.ws_col,
        .height = window_size.ws_row,
    };
}

pub fn prepare(self: *TerminalUI) !void {
    if (self.support.ansi_escape_codes) {
        try self.writer().writeAll(cursor_hide);
    }
}

pub fn deinit(self: *TerminalUI) void {
    if (self.support.ansi_escape_codes) {
        self.writer().writeAll(cursor_show) catch {};
    }
    self.flush() catch {};
    std.os.tcsetattr(self.in.handle, .FLUSH, self.original_termios) catch {};
}

pub fn writer(self: *TerminalUI) WriterCtx.Writer {
    return self.writer_ctx.writer();
}

pub fn flush(self: *TerminalUI) !void {
    try self.writer_ctx.flush();
}

pub fn clearScreen(self: *TerminalUI) !void {
    if (self.support.ansi_escape_codes) {
        try self.writer().writeAll(clear_all);
        try goTo(self.writer(), 1, 1);
    }
}

pub fn writeNewline(self: *TerminalUI) !void {
    if (self.support.ansi_escape_codes) {
        try self.writer().writeAll("\n\r");
    } else {
        try self.writer().writeAll("\n");
    }
}

fn goTo(w: anytype, x: u16, y: u16) !void {
    try std.fmt.format(w, csi ++ "{d};{d}H", .{ y, x });
}

fn base16LinuxConsoleNumber(base16_color: kisa.Color.Base16) u8 {
    return switch (base16_color) {
        .black => 0,
        .red => 1,
        .green => 2,
        .yellow => 3,
        .blue => 4,
        .magenta => 5,
        .cyan => 6,
        .white => 7,
        .black_bright => 8,
        .red_bright => 9,
        .green_bright => 10,
        .yellow_bright => 11,
        .blue_bright => 12,
        .magenta_bright => 13,
        .cyan_bright => 14,
        .white_bright => 15,
    };
}

fn writeFg(w: anytype, color: kisa.Color) !void {
    switch (color) {
        .rgb => |c| try std.fmt.format(w, csi ++ "38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        .base16 => |c| try std.fmt.format(w, csi ++ "38;5;{d}m", .{base16LinuxConsoleNumber(c)}),
        .special => return error.SpecialIsNotAColor,
    }
}

fn writeBg(w: anytype, color: kisa.Color) !void {
    switch (color) {
        .rgb => |c| try std.fmt.format(w, csi ++ "48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        .base16 => |c| try std.fmt.format(w, csi ++ "48;5;{d}m", .{base16LinuxConsoleNumber(c)}),
        .special => return error.SpecialIsNotAColor,
    }
}

fn writeFontStyle(w: anytype, font_style: kisa.FontStyle) !void {
    if (font_style.bold) try w.writeAll(style_bold);
    if (font_style.dim) try w.writeAll(style_dim);
    if (font_style.italic) try w.writeAll(style_italic);
    if (font_style.underline) try w.writeAll(style_underline);
    if (font_style.reverse) try w.writeAll(style_reverse);
    if (font_style.strikethrough) try w.writeAll(style_strikethrough);
}

fn writeStyleStart(self: *TerminalUI, style: kisa.Style) !void {
    var w = self.writer();
    if (self.support.ansi_escape_codes) {
        try writeFg(w, style.foreground);
        try writeBg(w, style.background);
        try writeFontStyle(w, style.font_style);
    }
}

fn writeStyleEnd(self: *TerminalUI) !void {
    if (self.support.ansi_escape_codes) {
        try self.writer().writeAll(style_reset);
    }
}

pub fn writeAllFormatted(self: *TerminalUI, style: kisa.Style, string: []const u8) !void {
    try self.writeStyleStart(style);
    try self.writer().writeAll(string);
    try self.writeStyleEnd();
}

pub fn writeByteNTimesFormatted(self: *TerminalUI, style: kisa.Style, byte: u8, n: usize) !void {
    try self.writeStyleStart(style);
    try self.writer().writeByteNTimes(byte, n);
    try self.writeStyleEnd();
}

// Run from project root: zig build run-terminal-ui
pub fn main() !void {
    var file = try std.fs.cwd().openFile("src/terminal_ui.zig", .{});
    const text = try file.readToEndAlloc(testing.allocator, std.math.maxInt(usize));
    defer testing.allocator.free(text);
    var ui = try TerminalUI.init(std.io.getStdIn(), std.io.getStdOut());
    defer ui.deinit();
    try ui.prepare();
    try ui.clearScreen();
    var text_it = std.mem.split(u8, text, "\n");
    const style = kisa.Style{
        .foreground = .{ .base16 = .yellow },
        .background = .{ .rgb = .{ .r = 33, .g = 33, .b = 33 } },
        .font_style = .{ .italic = true },
    };
    const style2 = kisa.Style{
        .foreground = .{ .base16 = .red },
        .background = .{ .rgb = .{ .r = 33, .g = 33, .b = 33 } },
    };
    var i: u32 = 0;
    while (text_it.next()) |line| {
        i += 1;
        if (i % 5 == 0) {
            try ui.writer().writeAll(line);
        } else if (i % 2 == 0) {
            try ui.writeFormatted(style, line);
        } else {
            try ui.writeFormatted(style2, line);
        }
        try ui.writeNewline();
    }
}

test "ui: reference all" {
    testing.refAllDecls(TerminalUI);
}
