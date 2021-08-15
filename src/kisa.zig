//! Common data structures and functionality used by various components of this application.

const std = @import("std");
const rpc = @import("rpc.zig");
const Server = @import("main.zig").Server;

/// Data sent to Client which represents the data to draw on the screen.
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

/// Parameters necessary to create new state in workspace and get `active_display_state`.
pub const ClientInitParams = struct {
    path: []const u8,
    readonly: bool,
    text_area_rows: u32,
    text_area_cols: u32,
};
