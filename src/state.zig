const std = @import("std");
const testing = std.testing;
const mem = std.mem;

/// Modes are different states of a display window which allow to interpret same keys as having
/// a different meaning.
pub const EditorMode = enum {
    normal,
    insert,
};

/// Workspace is a collection of all elements in code editor that can be considered a state.
pub const Workspace = struct {
    ally: *mem.Allocator,
    text_buffers: std.ArrayList(TextBuffer),
    display_windows: std.ArrayList(DisplayWindow),
    window_tabs: std.ArrayList(WindowTab),
    window_panes: std.ArrayList(WindowPane),

    const Self = @This();
    const Id = u32;

    pub fn init(ally: *mem.Allocator) Workspace {
        return Self{
            .ally = ally,
            .text_buffers = std.ArrayList(TextBuffer).init(ally),
            .display_windows = std.ArrayList(DisplayWindow).init(ally),
            .window_tabs = std.ArrayList(WindowTab).init(ally),
            .window_panes = std.ArrayList(WindowPane).init(ally),
        };
    }

    pub fn deinit(self: Self) void {
        for (self.text_buffers.items) |*text_buffer| text_buffer.deinit();
        self.text_buffers.deinit();
        for (self.display_windows.items) |*display_window| display_window.deinit();
        self.display_windows.deinit();
        for (self.window_tabs.items) |*window_tab| window_tab.deinit();
        self.window_tabs.deinit();
        for (self.window_panes.items) |*window_pane| window_pane.deinit();
        self.window_panes.deinit();
    }

    pub fn newWindow(self: *Self, content: []u8, rows: u32, cols: u32) !void {
        var text_buffer = try self.text_buffers.addOne();
        text_buffer.* = try TextBuffer.init(self, content);
        text_buffer.id = @intCast(Id, self.text_buffers.items.len);

        var display_window = try self.display_windows.addOne();
        display_window.* = DisplayWindow.init(self, rows, cols);
        display_window.id = @intCast(Id, self.display_windows.items.len);

        var window_tab = try self.window_tabs.addOne();
        window_tab.* = WindowTab.init(self);
        window_tab.id = @intCast(Id, self.window_tabs.items.len);

        var window_pane = try self.window_panes.addOne();
        window_pane.* = WindowPane.init(self);
        window_pane.id = @intCast(Id, self.window_panes.items.len);

        display_window.text_buffer_id = text_buffer.id;
        window_pane.window_tab_id = window_tab.id;
        display_window.window_pane_id = window_pane.id;
        window_pane.display_window_id = display_window.id;
        try window_tab.window_pane_ids.append(window_pane.id);
        try text_buffer.display_window_ids.append(display_window.id);
    }
};

test "workspace new window" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    var text = try testing.allocator.dupe(u8, "hello");
    try workspace.newWindow(text, 0, 0);
    const window_tab = workspace.window_tabs.items[0];
    const window_pane = workspace.window_panes.items[0];
    const display_window = workspace.display_windows.items[0];
    const text_buffer = workspace.text_buffers.items[0];

    try testing.expectEqual(@as(usize, 1), workspace.text_buffers.items.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.items.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.items.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.items.len);
    try testing.expectEqual(@as(usize, 1), window_tab.window_pane_ids.items.len);
    try testing.expectEqual(@as(usize, 1), text_buffer.display_window_ids.items.len);

    try testing.expectEqual(display_window.id, text_buffer.display_window_ids.items[0]);
    try testing.expectEqual(display_window.id, window_pane.display_window_id);
    try testing.expectEqual(window_tab.id, window_pane.window_tab_id);
    try testing.expectEqual(window_pane.id, window_tab.window_pane_ids.items[0]);
    try testing.expectEqual(window_pane.id, display_window.window_pane_id);
    try testing.expectEqual(text_buffer.id, display_window.text_buffer_id);
}

/// Editor can have several tabs, each tab can have several window panes.
pub const WindowTab = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    window_pane_ids: std.ArrayList(Workspace.Id),

    const Self = @This();

    pub fn init(workspace: *Workspace) Self {
        return Self{
            .workspace = workspace,
            .window_pane_ids = std.ArrayList(Workspace.Id).init(workspace.ally),
        };
    }

    pub fn deinit(self: Self) void {
        self.window_pane_ids.deinit();
    }
};

/// Editor tab can have several panes, each pane can have several display windows.
pub const WindowPane = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    window_tab_id: Workspace.Id = 0,
    display_window_id: Workspace.Id = 0,

    const Self = @This();

    pub fn init(workspace: *Workspace) Self {
        return Self{
            .workspace = workspace,
        };
    }

    pub fn deinit(self: Self) void {
        _ = self;
    }
};

/// Manages the actual text of an opened file and provides an interface for querying it and
/// modifying.
pub const TextBuffer = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    display_window_ids: std.ArrayList(Workspace.Id),
    content: std.ArrayList(u8),
    // metrics
    max_line_number: u32 = 0,

    const Self = @This();

    pub fn init(workspace: *Workspace, content: []u8) !Self {
        var result = Self{
            .workspace = workspace,
            .content = std.ArrayList(u8).fromOwnedSlice(workspace.ally, content),
            .display_window_ids = std.ArrayList(Workspace.Id).init(workspace.ally),
        };
        result.countMetrics();
        return result;
    }

    pub fn deinit(self: Self) void {
        self.content.deinit();
        self.display_window_ids.deinit();
    }

    fn countMetrics(self: *Self) void {
        self.max_line_number = 1;
        for (self.content.items) |ch| {
            if (ch == '\n') self.max_line_number += 1;
        }
    }

    pub fn toLineSlice(self: Self, first_line_number: u32, last_line_number: u32) ![]const u8 {
        var line_number: u32 = 1;
        var start_offset: usize = std.math.maxInt(usize);
        var end_offset: usize = std.math.maxInt(usize);
        const slice = self.content.items;
        for (slice) |ch, idx| {
            if (start_offset == std.math.maxInt(usize) and first_line_number == line_number) {
                start_offset = idx;
            }
            if (end_offset == std.math.maxInt(usize) and last_line_number == line_number) {
                end_offset = idx;
                break;
            }
            if (ch == '\n') line_number += 1;
        } else {
            // Screen height is more than we have text available
            end_offset = slice.len;
        }
        if (start_offset == std.math.maxInt(usize) or end_offset == std.math.maxInt(usize)) {
            std.debug.print(
                "first_line: {d}, last_line: {d}, line_num: {d}, start: {d}, end: {d}\n",
                .{ first_line_number, last_line_number, line_number, start_offset, end_offset },
            );
            return Error.LineOutOfRange;
        }
        return slice[start_offset..end_offset];
    }

    pub fn append(self: *Self, character: u8) !void {
        try self.content.append(character);
        self.countMetrics();
    }

    pub fn insert(self: *Self, index: usize, character: u8) !void {
        try self.content.insert(index, character);
        self.countMetrics();
    }
};

/// `Cursor` represents the current position of a cursor in a display window. `line` and `column`
/// are absolute values inside a file whereas `x` and `y` are relative coordinates to the
/// upper-left corner of the window.
pub const Cursor = struct {
    line: u32,
    column: u32,
    x: u32,
    y: u32,
};

/// Manages the data of what the user sees on the screen. Sends all the necessary data
/// to UI to display it on the screen. Also keeps the state of the opened window such
/// as cursor, mode etc.
pub const DisplayWindow = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    window_pane_id: Workspace.Id = 0,
    text_buffer_id: Workspace.Id = 0,
    rows: u32,
    cols: u32,
    cursor: Cursor,
    first_line_number: u32,
    mode: EditorMode,

    const Self = @This();
    const Error = UI.Error || TextBuffer.Error;

    pub fn init(workspace: *Workspace, rows: u32, cols: u32) Self {
        return Self{
            .workspace = workspace,
            .rows = rows,
            .cols = cols,
            .cursor = Cursor{ .line = 1, .column = 1, .x = 0, .y = 0 },
            .first_line_number = 1,
            .mode = .normal,
        };
    }

    pub fn deinit(self: Self) void {
        _ = self;
    }

    pub fn renderTextArea(self: *Self) Error!jsonrpc.SimpleRequest {
        const last_line_number = self.first_line_number + self.rows;
        const slice = try self.text_buffer.toLineSlice(self.first_line_number, last_line_number);
        const params = try self.text_buffer.ally.create([3]jsonrpc.Value);
        params.* = [_]jsonrpc.Value{
            .{ .String = slice },
            .{ .Integer = self.first_line_number },
            .{ .Integer = last_line_number },
        };
        return jsonrpc.SimpleRequest{
            .jsonrpc = jsonrpc.jsonrpc_version,
            .id = null,
            .method = "draw",
            .params = .{ .Array = params[0..] },
        };
    }
};
