//! Storage for common data reused by various components such as data structures.

const std = @import("std");

pub const DrawData = struct {
    lines: []const Line,

    pub const Line = struct {
        number: u32,
        contents: []const u8,
        face: Face = Face.default,
    };

    pub const Face = struct {
        fg: []const u8,
        bg: []const u8,
        attributes: []const Attribute = &[0]Attribute{},

        pub const default = Face{ .fg = "default", .bg = "default" };
    };

    pub const Attribute = enum {
        underline,
        reverse,
        bold,
        blink,
        dim,
        italic,

        pub fn jsonStringify(
            value: Attribute,
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            _ = options;
            try out_stream.writeAll(std.meta.tagName(value));
        }
    };
};
