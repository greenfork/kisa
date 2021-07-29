const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;

/// Currently active elements that are displayed on the client.
/// Assumes that these values can only be changed via 1 client and are always present in Workspace.
pub const ActiveDisplayState = struct {
    display_window_id: Workspace.Id,
    window_pane_id: Workspace.Id,
    window_tab_id: Workspace.Id,
};

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
    const TextBufferNode = std.TailQueue(TextBuffer).Node;
    const DisplayWindowNode = std.TailQueue(DisplayWindow).Node;
    const WindowTabNode = std.TailQueue(WindowTab).Node;
    const WindowPaneNode = std.TailQueue(WindowPane).Node;
    const IdNode = std.TailQueue(Id).Node;

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
        var window_pane = self.window_panes.first;
        while (window_pane) |wp| {
            window_pane = wp.next;
            wp.data.deinit();
            self.ally.destroy(wp);
        }
        var window_tab = self.window_tabs.first;
        while (window_tab) |wt| {
            window_tab = wt.next;
            wt.data.deinit();
            self.ally.destroy(wt);
        }
    }

    /// Initializes all the state elements for a new workspace.
    pub fn new(
        self: *Self,
        path: ?[]u8,
        content: []u8,
        text_area_rows: u32,
        text_area_cols: u32,
    ) !ActiveDisplayState {
        var text_buffer = try self.newTextBuffer(path, content);
        var display_window = try self.newDisplayWindow();
        var window_pane = try self.newWindowPane(text_area_rows, text_area_cols);
        var window_tab = try self.newWindowTab();

        display_window.data.text_buffer_id = text_buffer.data.id;
        window_pane.data.window_tab_id = window_tab.data.id;
        display_window.data.window_pane_id = window_pane.data.id;
        window_pane.data.display_window_id = display_window.data.id;
        try text_buffer.data.addDisplayWindowId(display_window.data.id);
        try window_tab.data.addWindowPaneId(window_pane.data.id);

        return ActiveDisplayState{
            .display_window_id = display_window.data.id,
            .window_pane_id = window_pane.data.id,
            .window_tab_id = window_tab.data.id,
        };
    }

    /// Adds text buffer, display window, removes old display window.
    /// Assumes that we open a new text buffer in the current window pane.
    pub fn addTextBuffer(
        self: *Self,
        active_display_state: ActiveDisplayState,
        path: ?[]u8,
        content: []u8,
    ) !ActiveDisplayState {
        var text_buffer = try self.newTextBuffer(path, content);
        var display_window = try self.newDisplayWindow();
        display_window.data.text_buffer_id = text_buffer.data.id;
        display_window.data.window_pane_id = active_display_state.window_pane_id;
        try text_buffer.data.addDisplayWindowId(display_window.data.id);
        var window_pane = self.findWindowPane(active_display_state.window_pane_id).?;
        window_pane.data.display_window_id = display_window.data.id;
        self.destroyDisplayWindow(active_display_state.display_window_id);
        return ActiveDisplayState{
            .display_window_id = display_window.data.id,
            .window_pane_id = active_display_state.window_pane_id,
            .window_tab_id = active_display_state.window_tab_id,
        };
    }

    /// Adds display window, removes old display window.
    /// Assumes that we open an existing text buffer in the current window pane.
    pub fn addDisplayWindow(
        self: *Self,
        active_display_state: ActiveDisplayState,
        text_buffer_id: Id,
    ) !ActiveDisplayState {
        if (self.findTextBuffer(text_buffer_id)) |text_buffer| {
            var display_window = try self.newDisplayWindow();
            display_window.data.text_buffer_id = text_buffer.data.id;
            display_window.data.window_pane_id = active_display_state.window_pane_id;
            var window_pane = self.findWindowPane(active_display_state.window_pane_id).?;
            window_pane.data.display_window_id = display_window.data.id;
            try text_buffer.data.addDisplayWindowId(display_window.data.id);
            text_buffer.data.removeDisplayWindowId(active_display_state.display_window_id);
            self.destroyDisplayWindow(active_display_state.display_window_id);
            return ActiveDisplayState{
                .display_window_id = display_window.data.id,
                .window_pane_id = active_display_state.window_pane_id,
                .window_tab_id = active_display_state.window_tab_id,
            };
        } else {
            return error.TextBufferNotFound;
        }
    }

    fn newTextBuffer(self: *Self, path: ?[]u8, content: []u8) !*TextBufferNode {
        var text_buffer = try self.ally.create(TextBufferNode);
        text_buffer.data = try TextBuffer.init(self, path, content);
        self.text_buffer_id_counter += 1;
        text_buffer.data.id = self.text_buffer_id_counter;
        self.text_buffers.append(text_buffer);
        return text_buffer;
    }

    fn newDisplayWindow(self: *Self) !*DisplayWindowNode {
        var display_window = try self.ally.create(DisplayWindowNode);
        display_window.data = DisplayWindow.init(self);
        self.display_window_id_counter += 1;
        display_window.data.id = self.display_window_id_counter;
        self.display_windows.append(display_window);
        return display_window;
    }

    fn newWindowPane(self: *Self, text_area_rows: u32, text_area_cols: u32) !*WindowPaneNode {
        var window_pane = try self.ally.create(WindowPaneNode);
        window_pane.data = WindowPane.init(self, text_area_rows, text_area_cols);
        self.window_pane_id_counter += 1;
        window_pane.data.id = self.window_pane_id_counter;
        self.window_panes.append(window_pane);
        return window_pane;
    }

    fn newWindowTab(self: *Self) !*WindowTabNode {
        var window_tab = try self.ally.create(WindowTabNode);
        window_tab.data = WindowTab.init(self);
        self.window_tab_id_counter += 1;
        window_tab.data.id = self.window_tab_id_counter;
        self.window_tabs.append(window_tab);
        return window_tab;
    }

    fn findTextBuffer(self: Self, id: Id) ?*TextBufferNode {
        var text_buffer = self.text_buffers.first;
        while (text_buffer) |tb| : (text_buffer = tb.next) {
            if (tb.data.id == id) return tb;
        }
        return null;
    }

    fn findDisplayWindow(self: Self, id: Id) ?*DisplayWindowNode {
        var display_window = self.display_windows.first;
        while (display_window) |dw| : (display_window = dw.next) {
            if (dw.data.id == id) return dw;
        }
        return null;
    }

    fn findWindowPane(self: Self, id: Id) ?*WindowPaneNode {
        var window_pane = self.window_panes.first;
        while (window_pane) |wp| : (window_pane = wp.next) {
            if (wp.data.id == id) return wp;
        }
        return null;
    }

    fn findWindowTab(self: Self, id: Id) ?*WindowTabNode {
        var window_tab = self.window_tabs.first;
        while (window_tab) |wt| : (window_tab = wt.next) {
            if (wt.data.id == id) return wt;
        }
        return null;
    }

    fn destroyTextBuffer(self: *Self, id: Id) void {
        if (self.findTextBuffer(id)) |text_buffer| {
            self.text_buffers.remove(text_buffer);
            text_buffer.data.deinit();
            self.ally.destroy(text_buffer);
        }
    }

    fn destroyDisplayWindow(self: *Self, id: Id) void {
        if (self.findDisplayWindow(id)) |display_window| {
            self.display_windows.remove(display_window);
            display_window.data.deinit();
            self.ally.destroy(display_window);
        }
    }

    fn destroyWindowPane(self: *Self, id: Id) void {
        if (self.findWindowPane(id)) |window_pane| {
            self.window_panes.remove(window_pane);
            window_pane.data.deinit();
            self.ally.destroy(window_pane);
        }
    }

    fn destroyWindowTab(self: *Self, id: Id) void {
        if (self.findWindowTab(id)) |window_tab| {
            self.window_tabs.remove(window_tab);
            window_tab.data.deinit();
            self.ally.destroy(window_tab);
        }
    }
};

test "new workspace" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    var text = try testing.allocator.dupe(u8, "hello");
    const active_display_state = try workspace.new(null, text, 1, 1);
    const window_tab = workspace.window_tabs.last.?;
    const window_pane = workspace.window_panes.last.?;
    const display_window = workspace.display_windows.last.?;
    const text_buffer = workspace.text_buffers.last.?;

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
    try testing.expectEqual(display_window.data.id, text_buffer.data.display_window_ids.last.?.data);
    try testing.expectEqual(window_pane.data.id, window_tab.data.window_pane_ids.last.?.data);

    try testing.expectEqual(window_pane.data.id, active_display_state.window_pane_id);
    try testing.expectEqual(window_tab.data.id, active_display_state.window_tab_id);
    try testing.expectEqual(display_window.data.id, active_display_state.display_window_id);
}

test "add text buffer to workspace" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    var old_text = try testing.allocator.dupe(u8, "hello");
    const old_active_display_state = try workspace.new(null, old_text, 1, 1);
    var text = try testing.allocator.dupe(u8, "hello");
    const active_display_state = try workspace.addTextBuffer(old_active_display_state, null, text);
    const window_tab = workspace.window_tabs.last.?;
    const window_pane = workspace.window_panes.last.?;
    const display_window = workspace.display_windows.last.?;
    const text_buffer = workspace.text_buffers.last.?;

    try testing.expectEqual(@as(usize, 2), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 1), window_tab.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 1), text_buffer.data.display_window_ids.len);

    try testing.expectEqual(display_window.data.id, window_pane.data.display_window_id);
    try testing.expectEqual(window_tab.data.id, window_pane.data.window_tab_id);
    try testing.expectEqual(window_pane.data.id, display_window.data.window_pane_id);
    try testing.expectEqual(text_buffer.data.id, display_window.data.text_buffer_id);
    try testing.expectEqual(display_window.data.id, text_buffer.data.display_window_ids.last.?.data);
    try testing.expectEqual(window_pane.data.id, window_tab.data.window_pane_ids.last.?.data);

    try testing.expectEqual(window_pane.data.id, active_display_state.window_pane_id);
    try testing.expectEqual(window_tab.data.id, active_display_state.window_tab_id);
    try testing.expectEqual(display_window.data.id, active_display_state.display_window_id);
}

test "add display window to workspace" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    var old_text = try testing.allocator.dupe(u8, "hello");
    const old_active_display_state = try workspace.new(null, old_text, 1, 1);
    const active_display_state = try workspace.addDisplayWindow(
        old_active_display_state,
        workspace.text_buffers.last.?.data.id,
    );
    const window_tab = workspace.window_tabs.last.?;
    const window_pane = workspace.window_panes.last.?;
    const display_window = workspace.display_windows.last.?;
    const text_buffer = workspace.text_buffers.last.?;

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
    try testing.expectEqual(display_window.data.id, text_buffer.data.display_window_ids.last.?.data);
    try testing.expectEqual(window_pane.data.id, window_tab.data.window_pane_ids.last.?.data);

    try testing.expectEqual(window_pane.data.id, active_display_state.window_pane_id);
    try testing.expectEqual(window_tab.data.id, active_display_state.window_tab_id);
    try testing.expectEqual(display_window.data.id, active_display_state.display_window_id);
}

/// Manages the actual text of an opened file and provides an interface for querying it and
/// modifying.
pub const TextBuffer = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    display_window_ids: std.TailQueue(Workspace.Id) = std.TailQueue(Workspace.Id){},
    content: std.ArrayList(u8),
    /// When path is null, it is a virtual buffer, meaning that it is not connected to a file.
    path: ?[]u8,
    // metrics
    max_line_number: u32 = 0,

    const Self = @This();

    /// Takes ownership of `path` and `content`, they must be allocated with `workspaces` allocator.
    pub fn init(workspace: *Workspace, path: ?[]u8, content: []u8) !Self {
        var result = Self{
            .workspace = workspace,
            .content = std.ArrayList(u8).fromOwnedSlice(workspace.ally, content),
            .path = path,
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

    pub fn addDisplayWindowId(self: *Self, id: Workspace.Id) !void {
        var display_window_id = try self.workspace.ally.create(Workspace.IdNode);
        display_window_id.data = id;
        self.display_window_ids.append(display_window_id);
    }

    pub fn removeDisplayWindowId(self: *Self, id: Workspace.Id) void {
        var display_window_id = self.display_window_ids.first;
        while (display_window_id) |dw_id| : (display_window_id = dw_id.next) {
            if (dw_id.data == id) {
                self.display_window_ids.remove(dw_id);
                self.workspace.ally.destroy(dw_id);
                return;
            }
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
    /// Absolute line position inside text buffer.
    line: u32,
    /// Absolute column position inside text buffer.
    column: u32,
};

/// Manages the data of what the user sees on the screen. Sends all the necessary data
/// to UI to display it on the screen. Also keeps the state of the opened window such
/// as cursor, mode etc.
pub const DisplayWindow = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    window_pane_id: Workspace.Id = 0,
    text_buffer_id: Workspace.Id = 0,
    cursor: Cursor,
    first_line_number: u32,
    mode: EditorMode,

    const Self = @This();

    pub fn init(workspace: *Workspace) Self {
        return Self{
            .workspace = workspace,
            .cursor = Cursor{ .line = 1, .column = 1 },
            .first_line_number = 1,
            .mode = .normal,
        };
    }

    pub fn deinit(self: Self) void {
        _ = self;
    }

    /// Text buffer could have been removed from server, it is not fully controlled by
    /// current display window.
    pub fn textBuffer(self: Self) ?*Workspace.TextBufferNode {
        self.workspace.findTextBuffer(self.text_buffer_id);
    }

    pub fn renderTextArea(self: *Self) !jsonrpc.SimpleRequest {
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

/// Editor tab can have several panes, each pane can have several display windows.
pub const WindowPane = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    window_tab_id: Workspace.Id = 0,
    display_window_id: Workspace.Id = 0,
    /// y dimension of available space.
    text_area_rows: u32,
    /// x dimension of available space.
    text_area_cols: u32,

    const Self = @This();

    pub fn init(workspace: *Workspace, text_area_rows: u32, text_area_cols: u32) Self {
        assert(text_area_rows != 0);
        assert(text_area_cols != 0);
        return Self{
            .workspace = workspace,
            .text_area_rows = text_area_rows,
            .text_area_cols = text_area_cols,
        };
    }

    pub fn deinit(self: Self) void {
        _ = self;
    }
};

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

    pub fn addWindowPaneId(self: *Self, id: Workspace.Id) !void {
        var window_pane_id = try self.workspace.ally.create(Workspace.IdNode);
        window_pane_id.data = id;
        self.window_pane_ids.append(window_pane_id);
    }

    pub fn removeWindowPaneId(self: *Self, id: Workspace.Id) void {
        var window_pane_id = self.window_pane_ids.first;
        while (window_pane_id) |wp_id| : (window_pane_id = wp_id.next) {
            if (wp_id.data == id) {
                self.window_pane_ids.remove(wp_id);
                self.workspace.ally.destroy(wp_id);
                return;
            }
        }
    }
};
