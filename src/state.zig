//! All components and data structures which are considered to be the "state" of a text editor.
//! Does not include communication-specific state, mostly this module is concerned with
//! editing and displaying of the text.
//! Should be an isolated component which doesn't know anything but the things it is concerned
//! about, meaning that this module must not interact with other code and just provide the
//! interface for others to use.
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;
const kisa = @import("kisa");

/// How Server sees a Client.
pub const Client = struct {
    id: Workspace.Id,
    active_display_state: ActiveDisplayState,

    const Self = @This();

    pub fn deinit(self: Self) void {
        _ = self;
    }
};

/// Currently active elements that are displayed on the client. Each client has 1 such struct
/// assigned but it is stored on the server still.
/// Assumes that these values can only be changed via 1 client and are always present in Workspace.
pub const ActiveDisplayState = struct {
    display_window_id: Workspace.Id,
    window_pane_id: Workspace.Id,
    window_tab_id: Workspace.Id,

    pub const empty = ActiveDisplayState{
        .display_window_id = 0,
        .window_pane_id = 0,
        .window_tab_id = 0,
    };
};

// More possible modes:
// * searching inside a file
// * typing in a command to execute
// * moving inside a file
// * ...
//
// More generally we can have these patterns for modes:
// * Type a full string and press Enter, e.g. type a named command to be executed
// * Type a string and we get an incremental changing of the result, e.g. search window
//   continuously displays different result based on the search term
// * Type a second key to complete the command, e.g. gj moves to the bottom and gk moves to the top
//   of a file, as a mnemocis "goto" and a direction with hjkl keys
// * Variation of the previous mode but it is "sticky", meaning it allows for several presses of
//   a key with a changed meaning, examples are "insert" mode and a "scrolling" mode

/// Modes are different states of an editor which allow to interpret same key presses differently.
pub const EditorMode = enum {
    normal,
    insert,
};

// Workspace supports actions, some optionally take a filename parameter which means they create new
// text buffer:
// * pane [filename] - create new window pane with current orientation and open last buffer
// * panev [filename] - for horizontal/vertical layout, create new window pane vertically
//   aligned and open last buffer
// * tab [filename] - create new tab and open last buffer
// * edit filename - open new or existing text buffer in current window pane
// * quit - close current window pane but keep text buffer, closes tab and/or editor if
//   current window pane is a single pane in the tab/editor
// * open-buffer - open existing text buffer in current window pane
// * delete-buffer - close current text buffer and open the next on in the current window pane
// * buffer-only - delete all text buffers but current buffer
// * next-buffer - open next text buffer in current window pane
// * prev-buffer - open previous text buffer in current window pane
// * last-buffer - open last opened buffer for current pane (not globally last opened)
// * next-pane - move active pane to next one
// * left-pane - for horizontal/vertical layout, move active pane to the left one
// * right-pane - for horizontal/vertical layout, move active pane to the right one
// * quit-editor - fully deinitialize all the state
//
// * pane - newWindowPane(orientation: vertical, fileparams: null)
// * pane filename - newWindowPane(orientation: vertical, fileparams: data)
// * panev - newWindowPane(orientation: horizontal, fileparams: null)
// * panev filename - newWindowPane(orientation: horizontal, fileparams: data)
// * tab - newWindowTab(fileparams: null)
// * tab filename - newWindowTab(fileparams: data)
// * edit filename - newTextBuffer(fileparams: data) / openTextBuffer()
// * quit - closeWindowPane()
// * open-buffer - openTextBuffer()
// * delete-buffer - closeTextBuffer()
// * delete-all-buffers - closeAllTextBuffers()
// * only-buffer - closeAllTextBuffersButCurrent()
// * next-buffer - switchTextBuffer(direction: next)
// * prev-buffer - switchTextBuffer(direction: previous)
// * last-buffer - switchTextBuffer(direction: last)
// * next-pane - switchWindowPane(direction: next)
// * prev-pane - switchWindowPane(direction: previous)
// * last-pane - switchWindowPane(direction: last)
// * left-pane - switchWindowPane(direction: left)
// * right-pane - switchWindowPane(direction: right)
// * quit-editor - deinit()

/// Workspace is a collection of all elements in code editor that can be considered a state,
/// as well as a set of actions to operate on them from a high-level perspective.
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

    pub const Id = u32;
    const Self = @This();
    const TextBufferNode = std.TailQueue(TextBuffer).Node;
    const DisplayWindowNode = std.TailQueue(DisplayWindow).Node;
    const WindowTabNode = std.TailQueue(WindowTab).Node;
    const WindowPaneNode = std.TailQueue(WindowPane).Node;
    const IdNode = std.TailQueue(Id).Node;
    const debug_buffer_id = 1;
    const scratch_buffer_id = 2;

    pub fn init(ally: *mem.Allocator) Self {
        return Self{ .ally = ally };
    }

    pub fn initDefaultBuffers(self: *Self) !void {
        const debug_buffer = try self.createTextBuffer(TextBuffer.InitParams{
            .path = null,
            .name = "*debug*",
            .content = "Debug buffer for error messages and debug information",
            .readonly = true,
        });
        errdefer self.destroyTextBuffer(debug_buffer.data.id);
        const scratch_buffer = try self.createTextBuffer(TextBuffer.InitParams{
            .path = null,
            .name = "*scratch*",
            .content = "Scratch buffer for notes and drafts",
        });
        errdefer self.destroyTextBuffer(scratch_buffer.data.id);
        assert(debug_buffer.data.id == debug_buffer_id);
        assert(scratch_buffer.data.id == scratch_buffer_id);
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

    fn checkInit(self: Self) void {
        var text_buffer = self.text_buffers.first;
        while (text_buffer) |tb| {
            text_buffer = tb.next;
            assert(tb.data.id != 0);
        }
        var display_window = self.display_windows.first;
        while (display_window) |dw| {
            display_window = dw.next;
            assert(dw.data.id != 0);
        }
        var window_pane = self.window_panes.first;
        while (window_pane) |wp| {
            window_pane = wp.next;
            assert(wp.data.id != 0);
        }
        var window_tab = self.window_tabs.first;
        while (window_tab) |wt| {
            window_tab = wt.next;
            assert(wt.data.id != 0);
        }
    }

    /// Initializes all the state elements for a new Client.
    pub fn new(
        self: *Self,
        text_buffer_init_params: TextBuffer.InitParams,
        window_pane_init_params: WindowPane.InitParams,
    ) !ActiveDisplayState {
        var text_buffer = try self.createTextBuffer(text_buffer_init_params);
        errdefer self.destroyTextBuffer(text_buffer.data.id);
        var display_window = try self.createDisplayWindow();
        errdefer self.destroyDisplayWindow(display_window.data.id);
        var window_pane = try self.createWindowPane(window_pane_init_params);
        errdefer self.destroyWindowPane(window_pane.data.id);
        var window_tab = try self.createWindowTab();
        errdefer self.destroyWindowTab(window_tab.data.id);

        try text_buffer.data.addDisplayWindowId(display_window.data.id);
        errdefer text_buffer.data.removeDisplayWindowId(display_window.data.id);
        try window_tab.data.addWindowPaneId(window_pane.data.id);
        errdefer window_tab.data.removeWindowPaneId(window_pane.data.id);

        display_window.data.text_buffer_id = text_buffer.data.id;
        window_pane.data.window_tab_id = window_tab.data.id;
        display_window.data.window_pane_id = window_pane.data.id;
        window_pane.data.display_window_id = display_window.data.id;

        self.checkInit();

        return ActiveDisplayState{
            .display_window_id = display_window.data.id,
            .window_pane_id = window_pane.data.id,
            .window_tab_id = window_tab.data.id,
        };
    }

    // TODO: rewrite
    pub fn draw(self: Self, active_display_state: ActiveDisplayState) kisa.DrawData {
        _ = self;
        _ = active_display_state;
        return kisa.DrawData{
            .lines = &[_]kisa.DrawData.Line{.{
                .number = 1,
                .contents = "hello",
            }},
        };
    }

    /// Adds text buffer, display window, removes old display window.
    pub fn newTextBuffer(
        self: *Self,
        active_display_state: ActiveDisplayState,
        text_buffer_init_params: TextBuffer.InitParams,
    ) !ActiveDisplayState {
        var text_buffer = try self.createTextBuffer(text_buffer_init_params);
        errdefer self.destroyTextBuffer(text_buffer.data.id);
        return self.openTextBuffer(
            active_display_state,
            text_buffer.data.id,
        ) catch |err| switch (err) {
            error.TextBufferNotFound => unreachable,
            else => |e| return e,
        };
    }

    /// Adds display window, removes old display window.
    pub fn openTextBuffer(
        self: *Self,
        active_display_state: ActiveDisplayState,
        text_buffer_id: Id,
    ) !ActiveDisplayState {
        if (self.findTextBuffer(text_buffer_id)) |text_buffer| {
            var display_window = try self.createDisplayWindow();
            errdefer self.destroyDisplayWindow(display_window.data.id);
            try text_buffer.data.addDisplayWindowId(display_window.data.id);
            errdefer text_buffer.data.removeDisplayWindowId(display_window.data.id);
            display_window.data.text_buffer_id = text_buffer.data.id;
            display_window.data.window_pane_id = active_display_state.window_pane_id;
            var window_pane = self.findWindowPane(active_display_state.window_pane_id).?;
            window_pane.data.display_window_id = display_window.data.id;
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

    pub fn newWindowPane(
        self: *Self,
        active_display_state: ActiveDisplayState,
        window_pane_init_params: WindowPane.InitParams,
    ) !ActiveDisplayState {
        var window_pane = try self.createWindowPane(window_pane_init_params);
        errdefer self.destroyWindowPane(window_pane.data.id);
        var display_window = try self.createDisplayWindow();
        errdefer self.destroyDisplayWindow(display_window.data.id);
        var window_tab = self.findWindowTab(active_display_state.window_tab_id).?;
        try window_tab.data.addWindowPaneId(window_pane.data.id);
        errdefer window_tab.data.removeWindowPaneId(window_pane.data.id);
        window_pane.data.window_tab_id = active_display_state.window_tab_id;
        window_pane.data.display_window_id = display_window.data.id;
        display_window.data.window_pane_id = window_pane.data.id;
        var text_buffer = self.text_buffers.last orelse return error.LastTextBufferAbsent;
        try text_buffer.data.addDisplayWindowId(display_window.data.id);
        errdefer text_buffer.data.removeDisplayWindowId(display_window.data.id);
        display_window.data.text_buffer_id = text_buffer.data.id;
        return self.openWindowPane(
            active_display_state,
            window_pane.data.id,
        ) catch |err| switch (err) {
            error.WindowPaneNotFound => unreachable,
            else => |e| return e,
        };
    }

    /// Switch active display state only.
    pub fn openWindowPane(
        self: *Self,
        active_display_state: ActiveDisplayState,
        window_pane_id: Id,
    ) !ActiveDisplayState {
        _ = active_display_state;
        if (self.findWindowPane(window_pane_id)) |window_pane| {
            return ActiveDisplayState{
                .display_window_id = window_pane.data.display_window_id,
                .window_pane_id = window_pane.data.id,
                .window_tab_id = window_pane.data.window_tab_id,
            };
        } else {
            return error.WindowPaneNotFound;
        }
    }

    // TODO: decide on the errors during `close` functions.
    // TODO: solve when we close current tab and switch to the next tab.
    /// When several window panes on same tab - Destroy DisplayWindow, WindowPane.
    pub fn closeWindowPane(
        self: *Self,
        active_display_state: ActiveDisplayState,
        window_pane_id: Id,
    ) !ActiveDisplayState {
        if (self.window_panes.len == 1) {
            // TODO: tell the outer world about our deinitialization and deinit.
            @panic("not implemented");
        } else {
            var window_tab = self.findWindowTab(active_display_state.window_tab_id).?;
            window_tab.data.removeWindowPaneId(window_pane_id);
            // errdefer window_tab.data.addWindowPaneId(window_pane_id) catch {};
            const display_window = self.findDisplayWindow(active_display_state.display_window_id).?;
            var text_buffer = self.findTextBuffer(
                display_window.data.text_buffer_id,
            ) orelse return error.ActiveTextBufferAbsent;
            text_buffer.data.removeDisplayWindowId(display_window.data.id);
            self.destroyDisplayWindow(active_display_state.display_window_id);
            self.destroyWindowPane(window_pane_id);

            const last_window_pane = self.window_panes.last.?;
            return ActiveDisplayState{
                .display_window_id = last_window_pane.data.display_window_id,
                .window_pane_id = last_window_pane.data.id,
                .window_tab_id = active_display_state.window_tab_id,
            };
        }
    }

    fn createTextBuffer(self: *Self, init_params: TextBuffer.InitParams) !*TextBufferNode {
        var text_buffer = try self.ally.create(TextBufferNode);
        text_buffer.data = try TextBuffer.init(self, init_params);
        self.text_buffer_id_counter += 1;
        text_buffer.data.id = self.text_buffer_id_counter;
        self.text_buffers.append(text_buffer);
        return text_buffer;
    }

    fn createDisplayWindow(self: *Self) !*DisplayWindowNode {
        var display_window = try self.ally.create(DisplayWindowNode);
        display_window.data = DisplayWindow.init(self);
        self.display_window_id_counter += 1;
        display_window.data.id = self.display_window_id_counter;
        self.display_windows.append(display_window);
        return display_window;
    }

    fn createWindowPane(self: *Self, init_params: WindowPane.InitParams) !*WindowPaneNode {
        var window_pane = try self.ally.create(WindowPaneNode);
        window_pane.data = WindowPane.init(self, init_params);
        self.window_pane_id_counter += 1;
        window_pane.data.id = self.window_pane_id_counter;
        self.window_panes.append(window_pane);
        return window_pane;
    }

    fn createWindowTab(self: *Self) !*WindowTabNode {
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

/// Assumes that all the currently active elements are the very last ones.
fn checkLastStateItemsCongruence(workspace: Workspace, active_display_state: ActiveDisplayState) !void {
    const window_tab = workspace.window_tabs.last.?;
    const window_pane = workspace.window_panes.last.?;
    const display_window = workspace.display_windows.last.?;
    const text_buffer = workspace.text_buffers.last.?;

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

test "state: new workspace" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    try workspace.initDefaultBuffers();
    const text_buffer_init_params = TextBuffer.InitParams{
        .content = "hello",
        .path = null,
        .name = "name",
    };
    const window_pane_init_params = WindowPane.InitParams{ .text_area_rows = 1, .text_area_cols = 1 };
    const active_display_state = try workspace.new(text_buffer_init_params, window_pane_init_params);

    try testing.expectEqual(@as(usize, 3), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.last.?.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 1), workspace.text_buffers.last.?.data.display_window_ids.len);

    try checkLastStateItemsCongruence(workspace, active_display_state);
}

test "state: new text buffer" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    try workspace.initDefaultBuffers();
    const old_text_buffer_init_params = TextBuffer.InitParams{
        .content = "hello",
        .path = null,
        .name = "name",
    };
    const window_pane_init_params = WindowPane.InitParams{ .text_area_rows = 1, .text_area_cols = 1 };
    const old_active_display_state = try workspace.new(old_text_buffer_init_params, window_pane_init_params);
    const text_buffer_init_params = TextBuffer.InitParams{
        .content = "hello2",
        .path = null,
        .name = "name2",
    };
    const active_display_state = try workspace.newTextBuffer(
        old_active_display_state,
        text_buffer_init_params,
    );

    try testing.expectEqual(@as(usize, 4), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.last.?.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 1), workspace.text_buffers.last.?.data.display_window_ids.len);

    try checkLastStateItemsCongruence(workspace, active_display_state);
}

test "state: open existing text buffer" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    try workspace.initDefaultBuffers();
    const text_buffer_init_params = TextBuffer.InitParams{
        .content = "hello",
        .path = null,
        .name = "name",
    };
    const window_pane_init_params = WindowPane.InitParams{ .text_area_rows = 1, .text_area_cols = 1 };
    const old_active_display_state = try workspace.new(text_buffer_init_params, window_pane_init_params);
    const active_display_state = try workspace.openTextBuffer(
        old_active_display_state,
        workspace.text_buffers.last.?.data.id,
    );

    try testing.expectEqual(@as(usize, 3), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.last.?.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 1), workspace.text_buffers.last.?.data.display_window_ids.len);

    try checkLastStateItemsCongruence(workspace, active_display_state);
}

test "state: handle failing conditions" {
    const failing_allocator = &testing.FailingAllocator.init(testing.allocator, 14).allocator;
    var workspace = Workspace.init(failing_allocator);
    defer workspace.deinit();
    try workspace.initDefaultBuffers();
    const text_buffer_init_params = TextBuffer.InitParams{ .content = "hello", .path = null, .name = "name" };
    const window_pane_init_params = WindowPane.InitParams{ .text_area_rows = 1, .text_area_cols = 1 };
    const old_active_display_state = try workspace.new(text_buffer_init_params, window_pane_init_params);
    try testing.expectError(error.OutOfMemory, workspace.openTextBuffer(
        old_active_display_state,
        workspace.text_buffers.last.?.data.id,
    ));

    try checkLastStateItemsCongruence(workspace, old_active_display_state);
}

test "state: new window pane" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    try workspace.initDefaultBuffers();
    const text_buffer_init_params = TextBuffer.InitParams{
        .content = "hello",
        .path = null,
        .name = "name",
    };
    const window_pane_init_params = WindowPane.InitParams{ .text_area_rows = 1, .text_area_cols = 1 };
    const old_active_display_state = try workspace.new(text_buffer_init_params, window_pane_init_params);
    const active_display_state = try workspace.newWindowPane(
        old_active_display_state,
        window_pane_init_params,
    );

    try testing.expectEqual(@as(usize, 3), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 2), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 2), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 2), workspace.window_tabs.last.?.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 2), workspace.text_buffers.last.?.data.display_window_ids.len);

    try checkLastStateItemsCongruence(workspace, active_display_state);
}

test "state: close window pane when there are several window panes on window tab" {
    var workspace = Workspace.init(testing.allocator);
    defer workspace.deinit();
    try workspace.initDefaultBuffers();
    const text_buffer_init_params = TextBuffer.InitParams{
        .content = "hello",
        .path = null,
        .name = "name",
    };
    const window_pane_init_params = WindowPane.InitParams{ .text_area_rows = 1, .text_area_cols = 1 };
    const old_active_display_state = try workspace.new(text_buffer_init_params, window_pane_init_params);
    const med_active_display_state = try workspace.newWindowPane(
        old_active_display_state,
        window_pane_init_params,
    );
    const active_display_state = try workspace.closeWindowPane(
        med_active_display_state,
        workspace.window_panes.last.?.data.id,
    );

    try testing.expectEqual(@as(usize, 3), workspace.text_buffers.len);
    try testing.expectEqual(@as(usize, 1), workspace.display_windows.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_panes.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.len);
    try testing.expectEqual(@as(usize, 1), workspace.window_tabs.last.?.data.window_pane_ids.len);
    try testing.expectEqual(@as(usize, 1), workspace.text_buffers.last.?.data.display_window_ids.len);

    try checkLastStateItemsCongruence(workspace, active_display_state);
}

/// Manages the content of an opened file on a filesystem or of a virtual file
/// and provides an interface for querying and modifying it.
pub const TextBuffer = struct {
    workspace: *Workspace,
    id: Workspace.Id = 0,
    display_window_ids: std.TailQueue(Workspace.Id) = std.TailQueue(Workspace.Id){},
    content: std.ArrayList(u8),
    /// When path is null, it is a virtual buffer, meaning that it is not connected to a file.
    path: ?[]u8,
    /// A textual representation of the buffer name, either path or name for virtual buffer.
    name: []u8,
    readonly: bool,
    // metrics
    max_line_number: u32 = 0,

    const Self = @This();

    pub const InitParams = struct {
        path: ?[]const u8,
        name: []const u8,
        content: ?[]const u8,
        readonly: bool = false,
    };

    /// Takes ownership of `path` and `content`, they must be allocated with `workspaces` allocator.
    pub fn init(workspace: *Workspace, init_params: InitParams) !Self {
        // TODO: file reading should be done in text buffer backend.
        const content = blk: {
            if (init_params.content) |cont| {
                break :blk try workspace.ally.dupe(u8, cont);
            } else if (init_params.path) |p| {
                var file = std.fs.openFileAbsolute(
                    p,
                    .{},
                ) catch |err| switch (err) {
                    error.PipeBusy => unreachable,
                    error.NotDir => unreachable,
                    error.PathAlreadyExists => unreachable,
                    error.WouldBlock => unreachable,
                    error.FileLocksNotSupported => unreachable,
                    error.SharingViolation,
                    error.AccessDenied,
                    error.SymLinkLoop,
                    error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded,
                    error.FileNotFound,
                    error.SystemResources,
                    error.NameTooLong,
                    error.NoDevice,
                    error.DeviceBusy,
                    error.FileTooBig,
                    error.NoSpaceLeft,
                    error.IsDir,
                    error.BadPathName,
                    error.InvalidUtf8,
                    error.Unexpected,
                    => |e| return e,
                };

                defer file.close();
                break :blk file.readToEndAlloc(
                    workspace.ally,
                    std.math.maxInt(usize),
                ) catch |err| switch (err) {
                    error.WouldBlock => unreachable,
                    error.BrokenPipe => unreachable,
                    error.ConnectionResetByPeer => unreachable,
                    error.ConnectionTimedOut => unreachable,
                    error.FileTooBig,
                    error.SystemResources,
                    error.IsDir,
                    error.OutOfMemory,
                    error.OperationAborted,
                    error.NotOpenForReading,
                    error.AccessDenied,
                    error.InputOutput,
                    error.Unexpected,
                    => |e| return e,
                };
            } else {
                return error.InitParamsMustHaveEitherPathOrContent;
            }
        };
        const path = blk: {
            if (init_params.path) |p| {
                break :blk try workspace.ally.dupe(u8, p);
            } else {
                break :blk null;
            }
        };
        const name = try workspace.ally.dupe(u8, init_params.name);
        var result = Self{
            .workspace = workspace,
            .content = std.ArrayList(u8).fromOwnedSlice(workspace.ally, content),
            .path = path,
            .name = name,
            .readonly = init_params.readonly,
        };
        return result;
    }

    pub fn deinit(self: Self) void {
        var display_window_id = self.display_window_ids.first;
        while (display_window_id) |dw_id| {
            display_window_id = dw_id.next;
            self.workspace.ally.destroy(dw_id);
        }
        self.content.deinit();
        if (self.path) |p| self.workspace.ally.free(p);
        self.workspace.ally.free(self.name);
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

    pub const InitParams = struct {
        text_area_rows: u32,
        text_area_cols: u32,
    };

    pub fn init(workspace: *Workspace, init_params: InitParams) Self {
        assert(init_params.text_area_rows != 0);
        assert(init_params.text_area_cols != 0);
        return Self{
            .workspace = workspace,
            .text_area_rows = init_params.text_area_rows,
            .text_area_cols = init_params.text_area_cols,
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
