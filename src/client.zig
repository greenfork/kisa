const std = @import("std");
const testing = std.testing;
const kisa = @import("kisa");
const TerminalUI = @import("terminal_ui.zig");
const sqlite = @import("sqlite");

var sqlite_diags = sqlite.Diagnostics{};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const ally = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(ally);
    defer arg_it.deinit();
    _ = arg_it.next() orelse unreachable; // binary name
    const filename = arg_it.next();
    if (filename) |fname| {
        std.debug.print("Supplied filename: {s}\n", .{fname});
    } else {
        std.debug.print("No filename Supplied\n", .{});
    }

    var db = try setupDb();

    const text_data = try db.oneAlloc([]const u8, ally, "SELECT data FROM kisa_text_data", .{}, .{});
    const typed_text = try std.json.parse(kisa.Text, &std.json.TokenStream.init(text_data.?), .{ .allocator = ally });
    defer std.json.parseFree(kisa.Text, typed_text, .{ .allocator = ally });
    std.debug.print("{}\n", .{typed_text});

    var ui = try TerminalUI.init(std.io.getStdIn(), std.io.getStdOut());
    defer ui.deinit();
    try ui.prepare();
}

fn setupDb() !sqlite.Db {
    var db = sqlite.Db.init(.{
        .mode = .{ .File = "kisa.db" },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .diags = &sqlite_diags,
    }) catch |err| {
        std.log.err("Unable to open a database, got error {}. Diagnostics: {s}", .{ err, sqlite_diags });
        return err;
    };

    const query = @embedFile("db_setup.sql");
    db.execMulti(query, .{ .diags = &sqlite_diags }) catch |err| {
        std.log.err("Unable to execute the statement, got error {}. Diagnostics: {s}", .{ err, sqlite_diags });
        return err;
    };
    return db;
}
