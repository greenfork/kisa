//! Common data structures and functionality used by various components of this application.
const std = @import("std");

/// Data sent to Client which represents the data to draw on the screen.
pub const Text = struct {
    /// Main data to draw on the screen.
    lines: []const Line,

    pub const Line = struct {
        number: u32,
        segments: []const Segment,

        pub const Segment = struct {
            /// Contents
            c: []const u8,
            style: Style = .{},
        };
    };

    pub fn format(
        value: Text,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        for (value.lines) |line| {
            try writer.print("{d}:\n", .{line.number});
            for (line.segments) |segment| {
                try writer.print("  {s} :: {}\n", .{ segment.c, segment.style });
            }
        }
    }
};

pub const Color = union(enum) {
    special: Special,
    base16: Base16,
    rgb: RGB,

    pub const Special = enum {
        default,

        pub fn jsonStringify(
            value: Special,
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            try std.json.stringify(std.meta.tagName(value), options, out_stream);
        }
    };

    pub const Base16 = enum {
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
        black_bright,
        red_bright,
        green_bright,
        yellow_bright,
        blue_bright,
        magenta_bright,
        cyan_bright,
        white_bright,

        pub fn jsonStringify(
            value: Base16,
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            try std.json.stringify(std.meta.tagName(value), options, out_stream);
        }
    };

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub fn format(
        value: Color,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (value) {
            .special => |s| try writer.writeAll(std.meta.tagName(s)),
            .base16 => |b16| try writer.writeAll(std.meta.tagName(b16)),
            .rgb => |rgb| try writer.print("rgb({d},{d},{d})", .{ rgb.r, rgb.g, rgb.b }),
        }
    }
};

pub const FontStyle = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,

    pub fn toData(self: FontStyle) u8 {
        var result: u8 = 0;
        if (self.bold) result += 1;
        if (self.dim) result += 2;
        if (self.italic) result += 4;
        if (self.underline) result += 8;
        if (self.reverse) result += 16;
        if (self.strikethrough) result += 32;
        return result;
    }

    pub fn fromData(data: u8) FontStyle {
        var result = FontStyle{};
        if (data & 1 != 0) result.bold = true;
        if (data & 2 != 0) result.dim = true;
        if (data & 4 != 0) result.italic = true;
        if (data & 8 != 0) result.underline = true;
        if (data & 16 != 0) result.reverse = true;
        if (data & 32 != 0) result.strikethrough = true;
        return result;
    }

    pub fn format(
        value: FontStyle,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var written = false;
        if (value.bold) {
            if (written) try writer.writeAll(",");
            try writer.writeAll("bold");
            written = true;
        }
        if (value.dim) {
            if (written) try writer.writeAll(",");
            try writer.writeAll("dim");
            written = true;
        }
        if (value.italic) {
            if (written) try writer.writeAll(",");
            try writer.writeAll("italic");
            written = true;
        }
        if (value.underline) {
            if (written) try writer.writeAll(",");
            try writer.writeAll("underline");
            written = true;
        }
        if (value.reverse) {
            if (written) try writer.writeAll(",");
            try writer.writeAll("reverse");
            written = true;
        }
        if (value.strikethrough) {
            if (written) try writer.writeAll(",");
            try writer.writeAll("strikethrough");
            written = true;
        }
        if (!written) {
            try writer.writeAll("none");
        }
    }
};

pub const Style = struct {
    fg: Color = .{ .special = .default },
    bg: Color = .{ .special = .default },
    /// FontStyle
    fs: u8 = 0,

    pub fn format(
        value: Style,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}:{}:{}", .{ value.fg, value.bg, FontStyle.fromData(value.fs) });
    }
};
