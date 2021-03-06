//! Editor configuration. Contains data structures corresponding to configuration and operations on
//! configuration files.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const EditorMode = @import("state.zig").EditorMode;
const zzz = @import("zzz");
const kisa = @import("kisa");

// TODO: display errors from config parsing.

pub const allowed_keypress_commands = [_]kisa.CommandKind{
    .nop,
    .insert_character,
    .cursor_move_down,
    .cursor_move_left,
    .cursor_move_right,
    .cursor_move_up,
    .quit,
    .save,
    .delete_line,
    .delete_word,
};

/// Must call first `init`, then `setup` for initialization.
/// Call `addConfigFile` to continuously add more and more config files in order of
/// precedence from lowest to highest. After that corresponding fields such as `keymap`
/// will be populated.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    ally: mem.Allocator,
    sources: std.ArrayList([]const u8),
    tree: Tree,
    keymap: Keymap,

    const max_nodes = 2048;
    pub const Tree = zzz.ZStaticTree(max_nodes);

    pub const Keymap = std.AutoHashMap(EditorMode, Bindings);
    pub const KeysToActions = std.HashMap(
        kisa.Key,
        Actions,
        kisa.Key.HashMapContext,
        std.hash_map.default_max_load_percentage,
    );

    pub const Bindings = struct {
        default: Actions,
        keys: KeysToActions,
    };

    pub const Actions = std.ArrayList(kisa.CommandKind);

    const Self = @This();

    pub fn init(ally: mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(ally),
            .ally = undefined,
            .sources = undefined,
            .tree = undefined,
            .keymap = undefined,
        };
    }

    pub fn setup(self: *Self) !void {
        self.ally = self.arena.allocator();
        self.sources = std.ArrayList([]const u8).init(self.ally);
        self.tree = Tree{};
        self.keymap = Keymap.init(self.ally);
        inline for (std.meta.fields(EditorMode)) |enum_field| {
            try self.keymap.put(@intToEnum(EditorMode, enum_field.value), Bindings{
                .default = Actions.init(self.ally),
                .keys = KeysToActions.init(self.ally),
            });
        }
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Add a config file.
    pub fn addConfigFile(self: *Self, absolute_path: []const u8) !void {
        var file = try std.fs.openFileAbsolute(absolute_path, .{});
        defer file.close();
        const text = try file.readToEndAlloc(self.ally, std.math.maxInt(usize));
        try self.addConfig(text, false);
    }

    // TODO: add several config files loading.
    /// Add config to current tree of configs. Several configs can be added consecutively,
    /// order matters, configs must be added from lowest to highest precedence. When `default`
    /// is `true`, it means that this is the very first initialization of a config and all the
    /// values must be present, it is an error if any value is missing.
    pub fn addConfig(self: *Self, content: []const u8, default: bool) !void {
        try zzz.appendText(&self.tree, null, content);
        const root = self.tree.root;
        if (root.findNthChild(0, "keymap")) |keymap| {
            var mode_it = keymap.nextChild(null);
            while (mode_it) |mode| : (mode_it = keymap.nextChild(mode_it)) {
                if (std.meta.stringToEnum(EditorMode, mode.value)) |editor_mode| {
                    var bindings = self.keymap.getPtr(editor_mode).?;
                    var bindings_it = mode.nextChild(null);
                    while (bindings_it) |binding| : (bindings_it = mode.nextChild(bindings_it)) {
                        var key_binding = blk: {
                            if (mem.eql(u8, "default", binding.value)) {
                                break :blk &bindings.default;
                            } else {
                                const key = try parseKeyDefinition(binding.value);
                                try bindings.keys.put(key, Actions.init(self.ally));
                                break :blk bindings.keys.getPtr(key).?;
                            }
                        };
                        var actions_it = binding.nextChild(null);
                        while (actions_it) |action| : (actions_it = binding.nextChild(actions_it)) {
                            action_loop: {
                                const command_kind = std.meta.stringToEnum(
                                    kisa.CommandKind,
                                    action.value,
                                ) orelse {
                                    std.debug.print("Unknown key action: {s}\n", .{action.value});
                                    return error.UnknownKeyAction;
                                };
                                for (allowed_keypress_commands) |allowed_command_kind| {
                                    if (command_kind == allowed_command_kind) {
                                        try key_binding.append(command_kind);
                                        break :action_loop;
                                    }
                                }
                                std.debug.print("{s}\n", .{command_kind});
                                return error.UnallowedKeyAction;
                            }
                        }
                    }
                    if (default and bindings.default.items.len == 0) return error.MissingDefault;
                } else {
                    return error.UnknownMode;
                }
            }
        }
    }

    pub fn resolveKey(self: Self, key: kisa.Key) kisa.Command {
        const actions = self.keymap.get(.normal).?.keys.get(key) orelse self.keymap.get(.normal).?.default;
        // TODO: different actions and proper casting with this type system.
        switch (actions.items[0]) {
            .cursor_move_down => {
                return @unionInit(kisa.Command, "cursor_move_down", {});
            },
            else => @panic("Not implemented"),
        }
    }

    fn parseKeyDefinition(string: []const u8) !kisa.Key {
        if (string.len == 1) {
            return kisa.Key.ascii(string[0]);
        } else if (special_keycode_map.get(string)) |keycode| {
            return kisa.Key{ .code = keycode };
        } else {
            var key = kisa.Key{ .code = undefined };
            var it = mem.split(u8, string, "-");
            while (it.next()) |part| {
                if (part.len == 1) {
                    key.code = kisa.Key.ascii(part[0]).code;
                    return key;
                } else if (special_keycode_map.get(part)) |keycode| {
                    key.code = keycode;
                    return key;
                } else if (mem.eql(u8, "ctrl", part)) {
                    key.addCtrl();
                } else if (mem.eql(u8, "shift", part)) {
                    key.addShift();
                } else if (mem.eql(u8, "alt", part)) {
                    key.addAlt();
                } else if (mem.eql(u8, "super", part)) {
                    key.addSuper();
                } else {
                    return error.UnknownKeyDefinition;
                }
            }
            return error.UnknownKeyDefinition;
        }
    }

    const special_keycode_map = std.ComptimeStringMap(kisa.keys.KeyCode, .{
        .{ "arrow_up", .{ .keysym = .arrow_up } },
        .{ "arrow_down", .{ .keysym = .arrow_down } },
        .{ "arrow_left", .{ .keysym = .arrow_left } },
        .{ "arrow_right", .{ .keysym = .arrow_right } },
        .{ "mouse_button_left", .{ .mouse_button = .left } },
        .{ "mouse_button_middle", .{ .mouse_button = .middle } },
        .{ "mouse_button_right", .{ .mouse_button = .right } },
        .{ "mouse_scroll_up", .{ .mouse_button = .scroll_up } },
        .{ "mouse_scroll_down", .{ .mouse_button = .scroll_down } },
        .{ "f1", .{ .function = 1 } },
        .{ "f2", .{ .function = 2 } },
        .{ "f3", .{ .function = 3 } },
        .{ "f4", .{ .function = 4 } },
        .{ "f5", .{ .function = 5 } },
        .{ "f6", .{ .function = 6 } },
        .{ "f7", .{ .function = 7 } },
        .{ "f8", .{ .function = 8 } },
        .{ "f9", .{ .function = 9 } },
        .{ "f10", .{ .function = 10 } },
        .{ "f11", .{ .function = 11 } },
        .{ "f12", .{ .function = 12 } },
    });

    pub fn format(
        value: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 0 or fmt.len == 1 and fmt[0] == 's') {
            const start_fmt =
                \\Config:
                \\  keymap:
                \\
            ;
            const mode_fmt =
                \\    {s}:
                \\
            ;
            const keybinding_single_fmt =
                \\      {s}: {s}
                \\
            ;
            const keybinding_key_fmt =
                \\      {s}:
                \\
            ;
            const keybinding_value_fmt =
                \\        {s}
                \\
            ;
            try std.fmt.format(writer, start_fmt, .{});
            var keymap_it = value.keymap.iterator();
            while (keymap_it.next()) |keymap_entry| {
                const mode = keymap_entry.key_ptr.*;
                const bindings = keymap_entry.value_ptr.*;
                try std.fmt.format(writer, mode_fmt, .{std.meta.tagName(mode)});
                try std.fmt.format(writer, keybinding_single_fmt, .{ "default", bindings.default.items[0] });
                var bindings_it = bindings.keys.iterator();
                while (bindings_it.next()) |binding_entry| {
                    const key = binding_entry.key_ptr.*;
                    const actions = binding_entry.value_ptr.*;
                    if (actions.items.len == 1) {
                        try std.fmt.format(writer, keybinding_single_fmt, .{ key, actions.items[0] });
                    } else {
                        try std.fmt.format(writer, keybinding_key_fmt, .{key});
                        for (actions.items) |action| {
                            try std.fmt.format(writer, keybinding_value_fmt, .{action});
                        }
                    }
                }
            }
        } else {
            @compileError("Unknown format character for Config: '" ++ fmt ++ "'");
        }
    }
};

test "config: add default config" {
    var ally = testing.allocator;
    const config_content =
        \\keymap:
        \\  normal:
        \\    h: cursor_move_left
        \\    j: cursor_move_down
        \\    k: cursor_move_up
        \\    l: cursor_move_right
        \\    n:
        \\      cursor_move_down
        \\      cursor_move_right
        \\    default: nop
        \\  insert:
        \\    default: insert_character
        \\    ctrl-alt-c: quit
        \\    ctrl-s: save
        \\    shift-d: delete_word
        \\    arrow_up: cursor_move_up
        \\    super-arrow_up: delete_line
    ;
    var config = Config.init(ally);
    defer config.deinit();
    try config.setup();
    try config.addConfig(config_content, true);

    const normal = config.keymap.get(.normal).?;
    const nkeys = normal.keys;
    const insert = config.keymap.get(.insert).?;
    const ikeys = insert.keys;
    const key_arrow_up = kisa.Key{ .code = .{ .keysym = .arrow_up } };
    const key_super_arrow_up = blk: {
        var key = kisa.Key{ .code = .{ .keysym = .arrow_up } };
        key.addSuper();
        break :blk key;
    };
    var ctrl_alt_c = kisa.Key.ascii('c');
    ctrl_alt_c.addCtrl();
    ctrl_alt_c.addAlt();

    try testing.expectEqual(@as(usize, 2), config.keymap.count());
    try testing.expectEqual(@as(usize, 5), nkeys.count());
    try testing.expectEqual(@as(usize, 5), ikeys.count());

    try testing.expectEqual(@as(usize, 1), normal.default.items.len);
    try testing.expectEqual(kisa.CommandKind.nop, normal.default.items[0]);
    try testing.expectEqual(@as(usize, 1), nkeys.get(kisa.Key.ascii('h')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.cursor_move_left, nkeys.get(kisa.Key.ascii('h')).?.items[0]);
    try testing.expectEqual(@as(usize, 1), nkeys.get(kisa.Key.ascii('j')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.cursor_move_down, nkeys.get(kisa.Key.ascii('j')).?.items[0]);
    try testing.expectEqual(@as(usize, 1), nkeys.get(kisa.Key.ascii('k')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.cursor_move_up, nkeys.get(kisa.Key.ascii('k')).?.items[0]);
    try testing.expectEqual(@as(usize, 1), nkeys.get(kisa.Key.ascii('l')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.cursor_move_right, nkeys.get(kisa.Key.ascii('l')).?.items[0]);
    try testing.expectEqual(@as(usize, 2), nkeys.get(kisa.Key.ascii('n')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.cursor_move_down, nkeys.get(kisa.Key.ascii('n')).?.items[0]);
    try testing.expectEqual(kisa.CommandKind.cursor_move_right, nkeys.get(kisa.Key.ascii('n')).?.items[1]);

    try testing.expectEqual(@as(usize, 1), insert.default.items.len);
    try testing.expectEqual(kisa.CommandKind.insert_character, insert.default.items[0]);
    try testing.expectEqual(@as(usize, 1), ikeys.get(kisa.Key.ctrl('s')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.save, ikeys.get(kisa.Key.ctrl('s')).?.items[0]);
    try testing.expectEqual(@as(usize, 1), ikeys.get(kisa.Key.shift('d')).?.items.len);
    try testing.expectEqual(kisa.CommandKind.delete_word, ikeys.get(kisa.Key.shift('d')).?.items[0]);
    try testing.expectEqual(@as(usize, 1), ikeys.get(key_arrow_up).?.items.len);
    try testing.expectEqual(kisa.CommandKind.cursor_move_up, ikeys.get(key_arrow_up).?.items[0]);
    try testing.expectEqual(@as(usize, 1), ikeys.get(key_super_arrow_up).?.items.len);
    try testing.expectEqual(kisa.CommandKind.delete_line, ikeys.get(key_super_arrow_up).?.items[0]);
    try testing.expectEqual(@as(usize, 1), ikeys.get(ctrl_alt_c).?.items.len);
    try testing.expectEqual(kisa.CommandKind.quit, ikeys.get(ctrl_alt_c).?.items[0]);
}
