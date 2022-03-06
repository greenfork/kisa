//! Here we always assume that data provided to functions is correct, for example kisa.Selection
//! has offsets less than buffer length.
const std = @import("std");
const testing = std.testing;
const kisa = @import("kisa");

const Highlight = @This();
const cursor_style = kisa.Style{
    .foreground = .{ .base16 = .black },
    .background = .{ .base16 = .white },
};
const selection_style = kisa.Style{
    .foreground = .{ .base16 = .white },
    .background = .{ .base16 = .blue },
};

// OPTIMIZE: use red-black tree?
/// Each segment does not overlap and they are always ordered.
segments: std.ArrayList(Segment),

// TODO: include here some Options from kisa.DrawData such as active_line_number.

pub fn init(ally: std.mem.Allocator) Highlight {
    return .{ .segments = std.ArrayList(Segment).init(ally) };
}

pub fn deinit(self: Highlight) void {
    self.segments.deinit();
}

pub const Segment = struct {
    start: usize,
    end: usize,
    style: kisa.Style,
};

// FIXME: segments must be always ordered on insertion and divided as needed.
pub fn addSegment(self: *Highlight, segment: Segment) !void {
    try self.segments.append(segment);
}

pub fn addSelection(highlight: *Highlight, s: kisa.Selection) !void {
    if (s.cursor.offset > s.anchor.offset) {
        try highlight.addSegment(.{
            .start = s.anchor.offset,
            .end = s.cursor.offset,
            .style = selection_style,
        });
    }
    try highlight.addSegment(.{
        .start = s.cursor.offset,
        .end = s.cursor.offset + 1,
        .style = cursor_style,
    });
    if (s.cursor.offset < s.anchor.offset) {
        try highlight.addSegment(.{
            .start = s.cursor.offset + 1,
            .end = s.anchor.offset + 1,
            .style = selection_style,
        });
    }
}

pub fn decorateLine(
    highlight: Highlight,
    ally: std.mem.Allocator,
    slice: []const u8,
    line_start: usize,
    line_end: usize,
) ![]const kisa.DrawData.Line.Segment {
    var segments = std.ArrayList(kisa.DrawData.Line.Segment).init(ally);
    var processed_index = line_start;
    for (highlight.segments.items) |highlight_segment| {
        if (highlight_segment.start > line_end) break;
        if (highlight_segment.end < line_start) continue;
        if (processed_index < highlight_segment.start) {
            try segments.append(kisa.DrawData.Line.Segment{
                .contents = slice[processed_index..highlight_segment.start],
            });
        }
        try segments.append(kisa.DrawData.Line.Segment{
            .contents = slice[highlight_segment.start..highlight_segment.end],
            .style = highlight_segment.style.toData(),
        });
        processed_index = highlight_segment.end;
    }
    try segments.append(kisa.DrawData.Line.Segment{
        .contents = slice[processed_index..line_end],
    });
    return segments.items;
}

/// `ally` should be an arena allocator which is freed after resulting `DrawData` is used.
pub fn synthesize(
    ally: std.mem.Allocator,
    highlight: Highlight,
    slice: []const u8,
    newline: []const u8,
) !kisa.DrawData {
    var lines = std.ArrayList(kisa.DrawData.Line).init(ally);
    var line_it = std.mem.split(u8, slice, newline);
    var line_number: u32 = 0;
    while (line_it.next()) |line| {
        line_number += 1;
        const line_offset = @ptrToInt(line.ptr) - @ptrToInt(slice.ptr);
        const segments = try highlight.decorateLine(
            ally,
            slice,
            line_offset,
            line_offset + line.len,
        );
        try lines.append(kisa.DrawData.Line{
            .number = line_number,
            .segments = segments,
        });
    }

    var max_line_number_length: u8 = 0;
    var max_line_number = std.mem.count(u8, slice, newline);
    while (max_line_number != 0) : (max_line_number = max_line_number / 10) {
        max_line_number_length += 1;
    }

    return kisa.DrawData{
        .max_line_number_length = max_line_number_length,
        .active_line_number = 0,
        .lines = lines.items,
    };
}

// Run from project root: zig build run-highlight
pub fn main() !void {
    const text =
        \\My first line
        \\def max(x, y)
        \\  if x > y
        \\    x
        \\  else
        \\    y
        \\  end
        \\end
        \\
    ;
    var hd = Highlight.init(testing.allocator);
    defer hd.deinit();
    try hd.addSelection(kisa.Selection{
        .cursor = .{ .offset = 2, .line = 1, .column = 1 },
        .anchor = .{ .offset = 0, .line = 1, .column = 1 },
    });
    try hd.addSelection(kisa.Selection{
        .cursor = .{ .offset = 6, .line = 1, .column = 1 },
        .anchor = .{ .offset = 8, .line = 1, .column = 1 },
    });
    try hd.addSelection(kisa.Selection{
        .cursor = .{ .offset = 10, .line = 1, .column = 1 },
        .anchor = .{ .offset = 10, .line = 1, .column = 1 },
    });
    var synthesize_arena = std.heap.ArenaAllocator.init(testing.allocator);
    const draw_data = try synthesize(synthesize_arena.allocator(), hd, text, "\n");
    defer synthesize_arena.deinit();

    const ui_api = @import("ui_api.zig");
    var ui = try ui_api.init(std.io.getStdIn(), std.io.getStdOut());
    defer ui.deinit();
    const default_style = kisa.Style{};
    try ui_api.draw(&ui, draw_data, .{
        .default_text_style = default_style,
        .line_number_separator = "| ",
        .line_number_style = .{ .font_style = .{ .underline = true } },
        .line_number_separator_style = .{ .foreground = .{ .base16 = .magenta } },
        .active_line_number_style = .{ .font_style = .{ .reverse = true } },
    });
}

test "highlight: reference all" {
    testing.refAllDecls(@This());
}

test "highlight: selection" {
    var hd = Highlight.init(testing.allocator);
    defer hd.deinit();
}
