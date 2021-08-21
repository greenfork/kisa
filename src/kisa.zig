//! Common data structures and functionality used by various components of this application.
const std = @import("std");
const rpc = @import("rpc.zig");
const Server = @import("main.zig").Server;

pub const keys = @import("keys.zig");
pub const Key = keys.Key;

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

pub const CommandKind = enum {
    nop,
    /// Params has information about the key.
    keypress,
    /// Sent by client when it quits.
    quitted,
    /// First value in params is the command kind, others are arguments to this command.
    initialize,
    quit,
    save,
    redraw,
    insert_character,
    cursor_move_down,
    cursor_move_left,
    cursor_move_up,
    cursor_move_right,
    delete_word,
    delete_line,
    open_file,
};

/// Command is a an action issued by client to be executed on the server.
pub const Command = union(CommandKind) {
    nop,
    /// Sent by client when it quits.
    quitted,
    quit,
    save,
    redraw,
    /// Provide initial parameters to initialize a client.
    initialize: ClientInitParams,
    /// Value is inserted character. TODO: should not be u8.
    insert_character: u8,
    keypress: Keypress,
    cursor_move_down,
    cursor_move_left,
    cursor_move_up,
    cursor_move_right,
    delete_word,
    delete_line,
    /// Value is absolute file path.
    open_file: struct { path: []const u8 },

    /// Parameters necessary to create new state in workspace and get `active_display_state`.
    pub const ClientInitParams = struct {
        path: []const u8,
        readonly: bool,
        text_area_rows: u32,
        text_area_cols: u32,
    };

    // pub const Multiplier = struct { multiplier: u32 = 1 };

    /// Different editing operations accept a numeric multiplier which specifies the number of
    /// times the operation should be executed.
    pub const Keypress = struct { key: Key, multiplier: u32 };
};
