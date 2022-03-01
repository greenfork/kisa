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
    try ui.clearScreen();
    return ui;
}

pub fn deinit(self: *UI) void {
    self.deinit();
}

fn parseColor(color: kisa.Color, default_color: kisa.Color) kisa.Color {
    switch (color) {
        .special => |special| return switch (special) {
            .default => default_color,
        },
        else => return color,
    }
}

fn parseFontStyle(
    font_style_attributes: []const kisa.FontStyle.Attribute,
    default_font_style: kisa.FontStyle,
) kisa.FontStyle {
    if (font_style_attributes.len == 0) return default_font_style;
    var font_style = kisa.FontStyle{};
    for (font_style_attributes) |attribute| {
        if (attribute == .bold) font_style.bold = true;
        if (attribute == .dim) font_style.dim = true;
        if (attribute == .italic) font_style.italic = true;
        if (attribute == .underline) font_style.underline = true;
        if (attribute == .reverse) font_style.reverse = true;
        if (attribute == .strikethrough) font_style.strikethrough = true;
    }
    return font_style;
}

fn parseSegmentStyle(style_data: kisa.Style.Data, default_style: kisa.Style) !kisa.Style {
    return kisa.Style{
        .foreground = parseColor(style_data.fg, default_style.foreground),
        .background = parseColor(style_data.bg, default_style.background),
        .font_style = parseFontStyle(style_data.attrs, default_style.font_style),
    };
}

pub fn draw(ui: *UI, draw_data: kisa.DrawData, default_style: kisa.Style) !void {
    switch (default_style.foreground) {
        .special => return error.DefaultStyleMustHaveConcreteColor,
        else => {},
    }
    switch (default_style.background) {
        .special => return error.DefaultStyleMustHaveConcreteColor,
        else => {},
    }
    var line_buf: [10]u8 = undefined;
    for (draw_data.lines) |line| {
        const line_str = try std.fmt.bufPrint(&line_buf, "{d}", .{line.number});
        if (line_str.len < draw_data.max_line_number_length)
            try ui.writer().writeByteNTimes(' ', draw_data.max_line_number_length - line_str.len);
        try ui.writer().writeAll(line_str);
        try ui.writer().writeByte(' ');
        for (line.segments) |segment| {
            const segment_style = try parseSegmentStyle(segment.style, default_style);
            try ui.writeFormatted(segment_style, segment.contents);
        }
        try ui.writeNewline();
    }
}

const draw_data_sample = kisa.DrawData{
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
                    .style = .{ .fg = .{ .base16 = .red } },
                },
                .{
                    .contents = "max",
                    .style = .{ .attrs = &[_]kisa.FontStyle.Attribute{.underline} },
                },
                .{
                    .contents = "(",
                },
                .{
                    .contents = "x",
                    .style = .{
                        .fg = .{ .base16 = .green },
                        .attrs = &[_]kisa.FontStyle.Attribute{.bold},
                    },
                },
                .{
                    .contents = ", ",
                },
                .{
                    .contents = "y",
                    .style = .{
                        .fg = .{ .base16 = .green },
                        .attrs = &[_]kisa.FontStyle.Attribute{.bold},
                    },
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
                    .style = .{ .fg = .{ .base16 = .blue } },
                },
                .{
                    .contents = " ",
                },
                .{
                    .contents = "x",
                    .style = .{
                        .fg = .{ .base16 = .green },
                        .attrs = &[_]kisa.FontStyle.Attribute{ .bold, .underline },
                    },
                },
                .{
                    .contents = " ",
                },
                .{
                    .contents = ">",
                    .style = .{ .fg = .{ .base16 = .yellow } },
                },
                .{
                    .contents = " ",
                },
                .{
                    .contents = "y",
                    .style = .{
                        .fg = .{ .base16 = .green },
                        .attrs = &[_]kisa.FontStyle.Attribute{ .bold, .underline },
                    },
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
                    .style = .{
                        .bg = .{ .rgb = .{ .r = 63, .g = 63, .b = 63 } },
                        .attrs = &[_]kisa.FontStyle.Attribute{.underline},
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
                    .style = .{ .fg = .{ .base16 = .blue } },
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
                    .style = .{
                        .bg = .{ .rgb = .{ .r = 63, .g = 63, .b = 63 } },
                        .attrs = &[_]kisa.FontStyle.Attribute{.underline},
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
                    .style = .{ .fg = .{ .base16 = .blue } },
                },
            },
        },
        .{
            .number = 10,
            .segments = &[_]kisa.DrawData.Line.Segment{
                .{
                    .contents = "end",
                    .style = .{ .fg = .{ .base16 = .red } },
                },
            },
        },
    },
};

// Run from project root: zig build run-ui
pub fn main() !void {
    var ui = try init(std.io.getStdIn(), std.io.getStdOut());
    defer ui.deinit();
    {
        const default_style = kisa.Style{
            .foreground = .{ .base16 = .white },
            .background = .{ .base16 = .black },
        };
        try draw(&ui, draw_data_sample, default_style);
    }
    {
        const default_style = kisa.Style{
            .foreground = .{ .base16 = .magenta_bright },
            .background = .{ .rgb = .{ .r = 55, .g = 55, .b = 55 } },
            .font_style = kisa.FontStyle{ .italic = true },
        };
        try draw(&ui, draw_data_sample, default_style);
    }
}

test "ui: reference all" {
    testing.refAllDecls(@This());
}

test "ui: generate/parse DrawData" {
    var generated = std.ArrayList(u8).init(testing.allocator);
    defer generated.deinit();
    try std.json.stringify(draw_data_sample, .{}, generated.writer());
    var token_stream = std.json.TokenStream.init(generated.items);
    const parsed = try std.json.parse(kisa.DrawData, &token_stream, .{ .allocator = testing.allocator });
    defer std.json.parseFree(kisa.DrawData, parsed, .{ .allocator = testing.allocator });
    try testing.expectEqual(draw_data_sample.max_line_number_length, parsed.max_line_number_length);
}
