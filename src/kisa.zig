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

pub const TextBufferMetrics = struct {
    max_line_number: u32 = 0,
};

pub const LineEnding = enum {
    unix,
    dos,
    old_mac,

    pub fn str(self: @This()) []const u8 {
        return switch (self) {
            .unix => "\n",
            .dos => "\r\n",
            .old_mac => "\r",
        };
    }
};

/// Pair of two positions in the buffer `cursor` and `anchor` that creates a selection of
/// characters. In the simple case when `cursor` and `anchor` positions are same, the selection
/// is of width 1.
pub const Selection = struct {
    /// Main caret position.
    cursor: Position,
    /// Caret position which creates selection if it is not same as `cursor`.
    anchor: Position,
    /// Whether to move `anchor` together with `cursor`.
    anchored: bool = false,
    /// For multiple cursors, primary cursor never leaves the display window.
    primary: bool = true,
    /// Used for next/previous line movements. Saves the column value and always tries to reach
    /// it even when the line does not have enough columns.
    transient_column: Dimension = 0,
    /// Used for next/previous line movements. Saves whether the cursor was at newline and always
    /// tries to reach a newline on consecutive lines. Takes precedence over `transient_column`.
    transient_newline: bool = false,

    const Self = @This();
    pub const Offset = u32;
    pub const Dimension = u32;
    pub const Position = struct { offset: Offset, line: Dimension, column: Dimension };

    pub fn moveTo(self: Self, position: Position) Self {
        var result = self;
        result.cursor = position;
        if (!self.anchored) result.anchor = position;
        return result;
    }

    pub fn resetTransients(self: Self) Self {
        var result = self;
        result.transient_column = 0;
        result.transient_newline = false;
        return result;
    }
};

pub const Selections = std.ArrayList(Selection);
