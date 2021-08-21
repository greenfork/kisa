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

pub const EventKind = enum {
    nop,
    /// Params has information about the key.
    keypress,
    /// Sent by client when it quits.
    quitted,
    /// First value in params is the event kind, others are arguments to this event.
    initialize,
    quit,
    save,
    request_draw_data,
    insert_character,
    cursor_move_down,
    cursor_move_left,
    cursor_move_up,
    cursor_move_right,
    delete_word,
    delete_line,
    open_file,
};

/// Event is a generic notion of an action happenning on the server, usually as a response to
/// client actions.
pub const Event = union(EventKind) {
    nop,
    /// Params has information about the key.
    keypress,
    /// Sent by client when it quits.
    quitted,
    /// Provide initial parameters to initialize a client.
    initialize,
    quit,
    save,
    request_draw_data,
    /// Value is inserted character.
    insert_character: u8,
    /// Value is multiplier.
    cursor_move_down: u32,
    /// Value is multiplier.
    cursor_move_left: u32,
    /// Value is multiplier.
    cursor_move_up: u32,
    /// Value is multiplier.
    cursor_move_right: u32,
    /// Value is multiplier.
    delete_word: u32,
    /// Value is multiplier.
    delete_line: u32,
    /// Value is absolute file path.
    open_file: struct { path: []const u8 },
};
