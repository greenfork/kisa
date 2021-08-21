//! Representation of a frontend-agnostic "key" which is supposed to encode any possible key
//! unambiguously. All UI frontends are supposed to provide a `Key` struct out of their `nextKey`
//! function for consumption by the backend.

const std = @import("std");

pub const KeySym = enum {
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,

    pub fn jsonStringify(
        value: KeySym,
        options: std.json.StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        _ = options;
        try out_stream.writeAll(std.meta.tagName(value));
    }
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    scroll_up,
    scroll_down,

    pub fn jsonStringify(
        value: MouseButton,
        options: std.json.StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        _ = options;
        try out_stream.writeAll(std.meta.tagName(value));
    }
};

pub const KeyCode = union(enum) {
    // How to represent a null value? See discussions below
    // https://github.com/ziglang/zig/issues/9415
    // https://github.com/greenfork/kisa/commit/23cfb17ae335dfe044eb4f1cd798deb37b48d569#r53652535
    // unrecognized: u0,
    unicode_codepoint: u32,
    function: u8,
    keysym: KeySym,
    mouse_button: MouseButton,
    mouse_position: struct { x: u32, y: u32 },
};

pub const Key = struct {
    code: KeyCode,
    modifiers: u8 = 0,
    // Any Unicode character can be UTF-8 encoded in no more than 6 bytes, plus terminating null
    utf8: [7]u8 = undefined,

    // zig fmt: off
        const shift_bit     = @as(u8, 1 << 0);
        const alt_bit       = @as(u8, 1 << 1);
        const ctrl_bit      = @as(u8, 1 << 2);
        const super_bit     = @as(u8, 1 << 3);
        const hyper_bit     = @as(u8, 1 << 4);
        const meta_bit      = @as(u8, 1 << 5);
        const caps_lock_bit = @as(u8, 1 << 6);
        const num_lock_bit  = @as(u8, 1 << 7);
        // zig fmt: on

    pub fn hasShift(self: Key) bool {
        return (self.modifiers & shift_bit) != 0;
    }
    pub fn hasAlt(self: Key) bool {
        return (self.modifiers & alt_bit) != 0;
    }
    pub fn hasCtrl(self: Key) bool {
        return (self.modifiers & ctrl_bit) != 0;
    }
    pub fn hasSuper(self: Key) bool {
        return (self.modifiers & super_bit) != 0;
    }
    pub fn hasHyper(self: Key) bool {
        return (self.modifiers & hyper_bit) != 0;
    }
    pub fn hasMeta(self: Key) bool {
        return (self.modifiers & meta_bit) != 0;
    }
    pub fn hasCapsLock(self: Key) bool {
        return (self.modifiers & caps_lock_bit) != 0;
    }
    pub fn hasNumLock(self: Key) bool {
        return (self.modifiers & num_lock_bit) != 0;
    }

    pub fn addShift(self: *Key) void {
        self.modifiers = self.modifiers | shift_bit;
    }
    pub fn addAlt(self: *Key) void {
        self.modifiers = self.modifiers | alt_bit;
    }
    pub fn addCtrl(self: *Key) void {
        self.modifiers = self.modifiers | ctrl_bit;
    }
    pub fn addSuper(self: *Key) void {
        self.modifiers = self.modifiers | super_bit;
    }
    pub fn addHyper(self: *Key) void {
        self.modifiers = self.modifiers | hyper_bit;
    }
    pub fn addMeta(self: *Key) void {
        self.modifiers = self.modifiers | meta_bit;
    }
    pub fn addCapsLock(self: *Key) void {
        self.modifiers = self.modifiers | caps_lock_bit;
    }
    pub fn addNumLock(self: *Key) void {
        self.modifiers = self.modifiers | num_lock_bit;
    }

    fn utf8len(self: Key) usize {
        var length: usize = 0;
        for (self.utf8) |byte| {
            if (byte == 0) break;
            length += 1;
        } else {
            unreachable; // we are responsible for making sure this never happens
        }
        return length;
    }
    pub fn isAscii(self: Key) bool {
        return self.code == .unicode_codepoint and self.utf8len() == 1;
    }
    pub fn isCtrl(self: Key, character: u8) bool {
        return self.isAscii() and self.utf8[0] == character and self.modifiers == ctrl_bit;
    }

    pub fn ascii(character: u8) Key {
        var key = Key{ .code = .{ .unicode_codepoint = character } };
        key.utf8[0] = character;
        key.utf8[1] = 0;
        return key;
    }
    pub fn ctrl(character: u8) Key {
        var key = ascii(character);
        key.addCtrl();
        return key;
    }
    pub fn alt(character: u8) Key {
        var key = ascii(character);
        key.addAlt();
        return key;
    }
    pub fn shift(character: u8) Key {
        var key = ascii(character);
        key.addShift();
        return key;
    }

    // We don't use `utf8` field for equality because it only contains necessary information
    // to represent other values and must not be considered to be always present.
    pub fn eql(a: Key, b: Key) bool {
        return std.meta.eql(a.code, b.code) and std.meta.eql(a.modifiers, b.modifiers);
    }
    pub fn hash(key: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, key.code);
        std.hash.autoHash(&hasher, key.modifiers);
        return hasher.final();
    }

    pub const HashMapContext = struct {
        pub fn hash(self: @This(), s: Key) u64 {
            _ = self;
            return Key.hash(s);
        }
        pub fn eql(self: @This(), a: Key, b: Key) bool {
            _ = self;
            return Key.eql(a, b);
        }
    };

    pub fn format(
        value: Key,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 1 and fmt[0] == 's') {
            try writer.writeAll("Key(");
            if (value.hasNumLock()) try writer.writeAll("num_lock-");
            if (value.hasCapsLock()) try writer.writeAll("caps_lock-");
            if (value.hasMeta()) try writer.writeAll("meta-");
            if (value.hasHyper()) try writer.writeAll("hyper-");
            if (value.hasSuper()) try writer.writeAll("super-");
            if (value.hasCtrl()) try writer.writeAll("ctrl-");
            if (value.hasAlt()) try writer.writeAll("alt-");
            if (value.hasShift()) try writer.writeAll("shift-");
            switch (value.code) {
                .unicode_codepoint => |val| {
                    try std.fmt.format(writer, "{c}", .{@intCast(u8, val)});
                },
                .function => |val| try std.fmt.format(writer, "f{d}", .{val}),
                .keysym => |val| try std.fmt.format(writer, "{s}", .{std.meta.tagName(val)}),
                .mouse_button => |val| try std.fmt.format(writer, "{s}", .{std.meta.tagName(val)}),
                .mouse_position => |val| {
                    try std.fmt.format(writer, "MousePosition({d},{d})", .{ val.x, val.y });
                },
            }
            try writer.writeAll(")");
        } else if (fmt.len == 0) {
            try std.fmt.format(
                writer,
                "{s}{{ .code = {}, .modifiers = {b}, .utf8 = {any} }}",
                .{ @typeName(@TypeOf(value)), value.code, value.modifiers, value.utf8 },
            );
        } else {
            @compileError("Unknown format character for Key: '" ++ fmt ++ "'");
        }
    }
};

test "keys: construction" {
    try std.testing.expect(!Key.ascii('c').hasCtrl());
    try std.testing.expect(Key.ctrl('c').hasCtrl());
    try std.testing.expect(Key.ascii('c').isAscii());
    try std.testing.expect(Key.ctrl('c').isAscii());
    try std.testing.expect(Key.ctrl('c').isCtrl('c'));
}
