//! Here we always assume that data provided to functions is correct, for example kisa.Selection
//! has offsets less than buffer length.
const std = @import("std");
const testing = std.testing;
const kisa = @import("kisa");
const rb = @import("rb.zig");
const assert = std.debug.assert;

const Highlight = @This();
const cursor_style = kisa.Style{
    .foreground = .{ .base16 = .black },
    .background = .{ .base16 = .white },
};
const selection_style = kisa.Style{
    .foreground = .{ .base16 = .white },
    .background = .{ .base16 = .blue },
};

ally: std.mem.Allocator,

/// A red-black tree of non-intersecting segments which are basically ranges with start and end.
segments: rb.Tree,

// TODO: include here some Options from kisa.DrawData such as active_line_number.
active_line_number: u32 = 0,

pub const Segment = struct {
    /// Part of a red-black tree.
    node: rb.Node = undefined,
    /// Inclusive.
    start: usize,
    /// Exclusive.
    end: usize,
    /// Color and style for the specified range in the text buffer.
    style: kisa.Style,
};

fn segmentsCompare(l: *rb.Node, r: *rb.Node, _: *rb.Tree) std.math.Order {
    const left = @fieldParentPtr(Segment, "node", l);
    const right = @fieldParentPtr(Segment, "node", r);
    assert(left.start < left.end);
    assert(right.start < right.end);

    // Intersecting segments are considered "equal". Current implementation of a red-black tree
    // does not allow duplicates, this insures that our tree will never have any intersecting
    // segments.
    if (left.end <= right.start) {
        return .lt;
    } else if (left.start >= right.end) {
        return .gt;
    } else {
        return .eq;
    }
}

pub fn init(ally: std.mem.Allocator) Highlight {
    return .{ .segments = rb.Tree.init(segmentsCompare), .ally = ally };
}

pub fn deinit(self: Highlight) void {
    var node = self.segments.first();
    while (node) |n| {
        node = n.next();
        self.ally.destroy(n);
    }
}

// Examples of common cases of segment overlapping:
// Let A be a segment: start=3, end=7 - base segment.
// Let B be a segment: start=8, end=10 - not overlapping.
// Let C be a segment: start=1, end=4 - overlapping from the start.
// Let D be a segment: start=6, end=10 - overlapping from the end.
// Let E be a segment: start=3, end=7 - complete overlapping.
// Let F be a segment: start=4, end=6 - overlapping in the middle.
pub fn addSegment(self: *Highlight, s: Segment) !void {
    if (s.start >= s.end) return error.StartMustBeLessThanEnd;

    var segment = try self.ally.create(Segment);
    errdefer self.ally.destroy(segment);
    segment.* = s;

    // insert returns a duplicated node if there's one, inserts the value otherwise.
    while (self.segments.insert(&segment.node)) |duplicated_node| {
        var duplicated_segment = @fieldParentPtr(Segment, "node", duplicated_node);

        if (segment.start <= duplicated_segment.start and segment.end >= duplicated_segment.end) {
            std.debug.print("A-E\n", .{});
            std.debug.print("segment: {d} - {d}, dup: {d} - {d}\n", .{ segment.start, segment.end, duplicated_segment.start, duplicated_segment.end });
            // A and E - complete overlapping.
            self.segments.remove(&duplicated_segment.node);
            self.ally.destroy(duplicated_segment);
        } else if (segment.start <= duplicated_segment.start and segment.end > duplicated_segment.start) {
            std.debug.print("A-C\n", .{});
            std.debug.print("segment: {d} - {d}, dup: {d} - {d}\n", .{ segment.start, segment.end, duplicated_segment.start, duplicated_segment.end });
            // A and C - overlapping from the start.
            duplicated_segment.start = segment.end;
        } else if (segment.start < duplicated_segment.end and segment.end >= duplicated_segment.end) {
            std.debug.print("A-D\n", .{});
            // A and D - overlapping from the end.
            duplicated_segment.end = segment.start;
        } else if (segment.start > duplicated_segment.start and segment.end < duplicated_segment.end) {
            std.debug.print("A-F\n", .{});
            // A and F - overlapping in the middle.

            // First half is the modified duplicated segment.
            duplicated_segment.end = segment.start;

            var second_half_segment = try self.ally.create(Segment);
            errdefer self.ally.destroy(second_half_segment);
            second_half_segment.* = .{
                .start = segment.end,
                .end = duplicated_segment.end,
                .style = duplicated_segment.style,
            };
            assert(self.segments.insert(&second_half_segment.node) != null);
        }
    }
    // At this point we should have resolved all possible overlapping scenarios.
    assert(self.segments.insert(&segment.node) != null);
}

pub fn addSelection(highlight: *Highlight, s: kisa.Selection) !void {
    if (s.primary) highlight.active_line_number = s.cursor.line;
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

pub fn addPattern(
    highlight: *Highlight,
    slice: []const u8,
    pattern: []const u8,
    style: kisa.Style,
) !void {
    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, slice, start_index, pattern)) |idx| {
        try highlight.addSegment(.{
            .start = idx,
            .end = idx + pattern.len,
            .style = style,
        });
        start_index = idx + pattern.len;
        if (start_index >= slice.len) break;
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
    var last_highlight_segment: ?*Highlight.Segment = null;

    var node = highlight.segments.first();
    while (node) |n| : (node = n.next()) {
        const highlight_segment = @fieldParentPtr(Segment, "node", n);
        std.debug.print("hs: {d} - {d}\n", .{ highlight_segment.start, highlight_segment.end });
    }
    while (node) |n| : (node = n.next()) {
        const highlight_segment = @fieldParentPtr(Segment, "node", n);
        if (highlight_segment.start > line_end) continue;
        if (highlight_segment.end < line_start) break;

        const start = std.math.max(highlight_segment.start, line_start);
        const end = std.math.min(highlight_segment.end, line_end);
        std.debug.print("start: {d}, end: {d}\n", .{ start, end });
        if (processed_index < start) {
            try segments.append(kisa.DrawData.Line.Segment{
                .contents = slice[processed_index..start],
            });
        }
        try segments.append(kisa.DrawData.Line.Segment{
            .contents = slice[start..end],
            .style = highlight_segment.style.toData(),
        });
        processed_index = end;
        last_highlight_segment = highlight_segment;
    }
    if (processed_index < line_end) {
        try segments.append(kisa.DrawData.Line.Segment{
            .contents = slice[processed_index..line_end],
        });
    } else if (last_highlight_segment != null and last_highlight_segment.?.end > line_end) {
        // Hihglight the newline at the end of line in case higlight segment spans several lines.
        try segments.append(kisa.DrawData.Line.Segment{
            .contents = " ",
            .style = last_highlight_segment.?.style.toData(),
        });
    }
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
        const line_offset = @ptrToInt(line.ptr) - @ptrToInt(slice.ptr);
        if (line_offset == slice.len) break; // if this is a line past the final newline
        line_number += 1;
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
    // +1 in case the file doesn't have a final newline.
    var max_line_number = std.mem.count(u8, slice, newline) + 1;
    while (max_line_number != 0) : (max_line_number = max_line_number / 10) {
        max_line_number_length += 1;
    }

    return kisa.DrawData{
        .max_line_number_length = max_line_number_length,
        .active_line_number = highlight.active_line_number,
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
        \\
    ;
    var hl = Highlight.init(testing.allocator);
    defer hl.deinit();
    try hl.addPattern(text, "end", kisa.Style{ .foreground = .{ .base16 = .blue } });
    try hl.addPattern(text, "e", kisa.Style{ .foreground = .{ .base16 = .red } });
    try hl.addSelection(kisa.Selection{
        .cursor = .{ .offset = 2, .line = 1, .column = 3 },
        .anchor = .{ .offset = 0, .line = 1, .column = 1 },
        .primary = false,
    });
    try hl.addSelection(kisa.Selection{
        .cursor = .{ .offset = 4, .line = 1, .column = 5 },
        .anchor = .{ .offset = 6, .line = 1, .column = 7 },
        .primary = false,
    });
    try hl.addSelection(kisa.Selection{
        .cursor = .{ .offset = 8, .line = 1, .column = 9 },
        .anchor = .{ .offset = 8, .line = 1, .column = 9 },
        .primary = false,
    });
    try hl.addSelection(kisa.Selection{
        .cursor = .{ .offset = 16, .line = 2, .column = 3 },
        .anchor = .{ .offset = 11, .line = 1, .column = 12 },
    });
    var synthesize_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer synthesize_arena.deinit();
    const draw_data = try synthesize(synthesize_arena.allocator(), hl, text, "\n");

    const ui_api = @import("ui_api.zig");
    var ui = try ui_api.init(std.io.getStdIn(), std.io.getStdOut());
    // defer ui.deinit();
    const default_style = kisa.Style{};
    try ui_api.draw(&ui, draw_data, .{
        .default_text_style = default_style,
        .line_number_separator = "| ",
        .line_number_style = .{ .font_style = .{ .underline = true } },
        .line_number_separator_style = .{ .foreground = .{ .base16 = .magenta } },
        .active_line_number_style = .{ .font_style = .{ .reverse = true } },
    });
    ui.deinit();

    // for (hl.segments.items) |s| {
    //     std.debug.print("start: {d}, end: {d}\n", .{ s.start, s.end });
    // }
    for (draw_data.lines) |line| {
        std.debug.print("{d}: ", .{line.number});
        for (line.segments) |s| {
            std.debug.print("{s}, ", .{s.contents});
        }
        std.debug.print("\n", .{});
    }
}

test "highlight: reference all" {
    testing.refAllDecls(@This());
}
