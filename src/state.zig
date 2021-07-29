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
    text_buffers: std.TailQueue(TextBuffer) = std.TailQueue(TextBuffer){},
    display_windows: std.TailQueue(DisplayWindow) = std.TailQueue(DisplayWindow){},
    window_tabs: std.TailQueue(WindowTab) = std.TailQueue(WindowTab){},
    window_panes: std.TailQueue(WindowPane) = std.TailQueue(WindowPane){},
    text_buffer_id_counter: Id = 0,
    display_window_id_counter: Id = 0,
    window_tab_id_counter: Id = 0,
    window_pane_id_counter: Id = 0,

    const Self = @This();
    const Id = u32;

    pub fn init(ally: *mem.Allocator) Workspace {
        return Self{ .ally = ally };
    }

    pub fn deinit(self: Self) void {
        var text_buffer = self.text_buffers.first;
        while (text_buffer) |tb| {
            text_buffer = tb.next;
            tb.data.deinit();
            self.ally.destroy(tb);
        }
        var display_window = self.display_windows.first;
        while (display_window) |dw| {
            display_window = dw.next;
            dw.data.deinit();
            self.ally.destroy(dw);
        }
        var window_tab = self.window_tabs.first;
        while (window_tab) |wt| {
            window_tab = wt.next;
            wt.data.deinit();
            self.ally.destroy(wt);
        }
        var window_pane = self.window_panes.first;
        while (window_pane) |wp| {
            window_pane = wp.next;
            wp.data.deinit();
            self.ally.destroy(wp);
        }
    }

    pub fn newWindow(self: *Self, content: []u8, row: u32, col: u32) !void {
        var text_buffer = try self.ally.create(std.TailQueue(TextBuffer).Node);
        text_buffer.data = try TextBuffer.init(self, content);
        self.text_buffer_id_counter += 1;
        text_buffer.data.id = self.text_buffer_id_counter;
        self.text_buffers.append(text_buffer);

        var display_window = try self.ally.create(std.TailQueue(DisplayWindow).Node);
        display_window.data = DisplayWindow.init(self, row, col);
        self.display_window_id_counter += 1;
        display_window.data.id = self.display_window_id_counter;
        self.display_windows.append(display_window);

        var window_tab = try self.ally.create(std.TailQueue(WindowTab).Node);
        window_tab.data = WindowTab.init(self);
        self.window_tab_id_counter += 1;
        window_tab.data.id = self.window_tab_id_counter;
        self.window_tabs.append(window_tab);

        var window_pane = try self.ally.create(std.TailQueue(WindowPane).Node);
        window_pane.data = WindowPane.init(self);
        self.window_pane_id_counter += 1;
        window_pane.data.id = self.window_pane_id_counter;
        self.window_panes.append(window_pane);

        display_window.data.text_buffer_id = text_buffer.data.id;
        window_pane.data.window_tab_id = window_tab.data.id;
        display_window.data.window_pane_id = window_pane.data.id;
        window_pane.data.display_window_id = display_window.data.id;

        var window_pane_id = try self.ally.create(std.TailQueue(Id).Node);
        window_pane_id.data = window_pane.data.id;
        window_tab.data.window_pane_ids.append(window_pane_id);
        var display_window_id = try self.ally.create(std.TailQueue(Id).Node);
        display_window_id.data = display_window.data.id;
        text_buffer.data.display_window_ids.append(display_window_id);
    }
};

test "workspace new window" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    var text = try testing.allocator.dupe(u8, "hello");
    try workspace.newWindow(text, 0, 0);
    const window_tab = workspace.window_tabs.first.?;
    const window_pane = workspace.window_panes.first.?;
    const display_window = workspace.display_windows.first.?;
    const text_buffer = workspace.text_buffers.first.?;

    try testing.expectEqual(@as(usize, 1), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 1), window_tab.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 1), text_buffer.data.display_window_ids.len);

    try testing.expectEqual(display_window.data.id, window_pane.data.display_window_id);
    try testing.expectEqual(window_tab.data.id, window_pane.data.window_tab_id);
    try testing.expectEqual(window_pane.data.id, display_window.data.window_pane_id);
    try testing.expectEqual(text_buffer.data.id, display_window.data.text_buffer_id);
    try testing.expectEqual(display_window.data.id, text_buffer.data.display_window_ids.first.?.data);
    try testing.expectEqual(window_pane.data.id, window_tab.data.window_pane_ids.first.?.data);
}

/// Editor can have several tabs, each tab can have several window panes.
pub const WindowTab = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    window_pane_ids: std.TailQueue(Workspace.Id) = std.TailQueue(Workspace.Id){},

    const Self = @This();

    pub fn init(workspace: *Workspace) Self {
        return Self{ .workspace = workspace };
    }

    pub fn deinit(self: Self) void {
        var window_pane_id = self.window_pane_ids.first;
        while (window_pane_id) |wp_id| {
            window_pane_id = wp_id.next;
            self.workspace.ally.destroy(wp_id);
        }
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
    display_window_ids: std.TailQueue(Workspace.Id) = std.TailQueue(Workspace.Id){},
    content: std.ArrayList(u8),
    // metrics
    max_line_number: u32 = 0,

    const Self = @This();

    pub fn init(workspace: *Workspace, content: []u8) !Self {
        var result = Self{
            .workspace = workspace,
            .content = std.ArrayList(u8).fromOwnedSlice(workspace.ally, content),
        };
        result.countMetrics();
        return result;
    }

    pub fn deinit(self: Self) void {
        self.content.deinit();
        var display_window_id = self.display_window_ids.first;
        while (display_window_id) |dw_id| {
            display_window_id = dw_id.next;
            self.workspace.ally.destroy(dw_id);
        }
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
