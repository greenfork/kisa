const std = @import("std");
const testing = std.testing;
const kisa = @import("kisa");
pub const UI = @import("terminal_ui.zig");

comptime {
    const interface_functions = [_][]const u8{
        "init",
        "prepare",
        "deinit",
        "writer",
        "flush",
        "clearScreen",
        "writeNewline",
        "writeFormatted",
    };
    for (interface_functions) |f| {
        if (!std.meta.trait.hasFn(f)(UI)) {
            @compileError("'UI' interface does not implement function '" ++ f ++ "'");
        }
    }
}

pub fn init(in: std.fs.File, out: std.fs.File) !UI {
    var ui = try UI.init(in, out);
    try ui.prepare();
    return ui;
}

pub fn deinit(self: *UI) void {
    self.deinit();
}

fn parseColor(face_color: []const u8, default_color: kisa.Color) !kisa.Color {
    if (kisa.Color.string_map.get(face_color)) |color| {
        return color;
    } else if (std.mem.eql(u8, "default", face_color)) {
        return default_color;
    } else if (std.mem.startsWith(u8, face_color, "rgb(") and std.mem.endsWith(u8, face_color, ")")) {
        var rgb_it = std.mem.tokenize(u8, face_color[4 .. face_color.len - 1], ", ");
        const r_str = rgb_it.next() orelse return error.InvalidRGBFormat;
        const g_str = rgb_it.next() orelse return error.InvalidRGBFormat;
        const b_str = rgb_it.next() orelse return error.InvalidRGBFormat;
        if (rgb_it.next() != null) return error.InvalidRGBFormat;
        const r = try std.fmt.parseInt(u8, r_str, 10);
        const g = try std.fmt.parseInt(u8, g_str, 10);
        const b = try std.fmt.parseInt(u8, b_str, 10);
        return kisa.Color{ .rgb = .{ .r = r, .g = g, .b = b } };
    } else {
        return error.InvalidFormat;
    }
}

fn parseFontStyle(
    face_attributes: []const kisa.DrawData.Face.Attribute,
    default_font_style: kisa.FontStyle,
) kisa.FontStyle {
    if (face_attributes.len == 0) return default_font_style;
    var font_style = kisa.FontStyle{};
    for (face_attributes) |attribute| {
        if (attribute == .bold) font_style.bold = true;
        if (attribute == .dim) font_style.dim = true;
        if (attribute == .italic) font_style.italic = true;
        if (attribute == .underline) font_style.underline = true;
        if (attribute == .reverse) font_style.reverse = true;
        if (attribute == .strikethrough) font_style.strikethrough = true;
    }
    return font_style;
}

fn parseSegmentStyle(face: kisa.DrawData.Face, default_style: kisa.Style) !kisa.Style {
    return kisa.Style{
        .foreground = try parseColor(face.fg, default_style.foreground),
        .background = try parseColor(face.bg, default_style.background),
        .font_style = parseFontStyle(face.attributes, default_style.font_style),
    };
}

pub fn draw(ui: *UI, draw_data: kisa.DrawData, default_style: kisa.Style) !void {
    var line_buf: [10]u8 = undefined;
    for (draw_data.lines) |line| {
        const line_str = try std.fmt.bufPrint(&line_buf, "{d}", .{line.number});
        if (line_str.len < draw_data.max_line_number_length)
            try ui.writer().writeByteNTimes(' ', draw_data.max_line_number_length - line_str.len);
        try ui.writer().writeAll(line_str);
        try ui.writer().writeByte(' ');
        for (line.segments) |segment| {
            const segment_style = try parseSegmentStyle(segment.face, default_style);
            try ui.writeFormatted(segment_style, segment.contents);
        }
        try ui.writeNewline();
    }
}

// Run from project root: zig build run-ui
pub fn main() !void {
    const draw_data = kisa.DrawData{
        .max_line_number_length = 3,
        .lines = &[_]kisa.DrawData.Line{
            .{
                .number = 1,
                .segments = &[_]kisa.DrawData.Line.Segment{.{ .contents = "My first line" }},
            },
            .{
                .number = 2,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "def ",
                        .face = .{ .fg = "red" },
                    },
                    .{
                        .contents = "max",
                        .face = .{ .attributes = &[_]kisa.DrawData.Face.Attribute{.underline} },
                    },
                    .{
                        .contents = "(",
                    },
                    .{
                        .contents = "x",
                        .face = .{ .fg = "green", .attributes = &[_]kisa.DrawData.Face.Attribute{.bold} },
                    },
                    .{
                        .contents = ", ",
                    },
                    .{
                        .contents = "y",
                        .face = .{ .fg = "green", .attributes = &[_]kisa.DrawData.Face.Attribute{.bold} },
                    },
                    .{
                        .contents = ")",
                    },
                },
            },
            .{
                .number = 3,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "  ",
                    },
                    .{
                        .contents = "if",
                        .face = .{ .fg = "blue" },
                    },
                    .{
                        .contents = " ",
                    },
                    .{
                        .contents = "x",
                        .face = .{ .fg = "green", .attributes = &[_]kisa.DrawData.Face.Attribute{ .bold, .underline } },
                    },
                    .{
                        .contents = " ",
                    },
                    .{
                        .contents = ">",
                        .face = .{ .fg = "yellow" },
                    },
                    .{
                        .contents = " ",
                    },
                    .{
                        .contents = "y",
                        .face = .{ .fg = "green", .attributes = &[_]kisa.DrawData.Face.Attribute{ .bold, .underline } },
                    },
                },
            },
            .{
                .number = 4,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "    ",
                    },
                    .{
                        .contents = "x",
                        .face = .{
                            .bg = "rgb(63, 63, 63)",
                            .attributes = &[_]kisa.DrawData.Face.Attribute{.underline},
                        },
                    },
                },
            },
            .{
                .number = 5,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "  ",
                    },
                    .{
                        .contents = "else",
                        .face = .{ .fg = "blue" },
                    },
                },
            },
            .{
                .number = 6,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "    ",
                    },
                    .{
                        .contents = "y",
                        .face = .{
                            .bg = "rgb(63, 63, 63)",
                            .attributes = &[_]kisa.DrawData.Face.Attribute{.underline},
                        },
                    },
                },
            },
            .{
                .number = 7,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "  ",
                    },
                    .{
                        .contents = "end",
                        .face = .{ .fg = "blue" },
                    },
                },
            },
            .{
                .number = 10,
                .segments = &[_]kisa.DrawData.Line.Segment{
                    .{
                        .contents = "end",
                        .face = .{ .fg = "red" },
                    },
                },
            },
        },
    };

    var ui = try UI.init(std.io.getStdIn(), std.io.getStdOut());
    defer ui.deinit();
    try ui.prepare();
    try ui.clearScreen();
    {
        const default_style = kisa.Style{};
        try draw(&ui, draw_data, default_style);
    }
    {
        const default_style = kisa.Style{
            .foreground = .magenta_bright,
            .background = .{ .rgb = .{ .r = 55, .g = 55, .b = 55 } },
            .font_style = kisa.FontStyle{ .italic = true },
        };
        try draw(&ui, draw_data, default_style);
    }
}

test "ui: reference all" {
    testing.refAllDecls(@This());
}
