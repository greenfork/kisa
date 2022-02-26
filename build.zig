const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("kisa", "src/main.zig");
    exe.addPackagePath("zzz", "libs/zzz/src/main.zig");
    exe.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
    exe.addPackagePath("ziglyph", "libs/ziglyph/src/ziglyph.zig");
    exe.addPackagePath("kisa", "src/kisa.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_terminal_ui = b.step("run-terminal-ui", "Run demonstration of terminal UI");
    const terminal_ui = b.addExecutable("terminal_ui", "src/terminal_ui.zig");
    terminal_ui.addPackagePath("kisa", "src/kisa.zig");
    terminal_ui.setTarget(target);
    terminal_ui.setBuildMode(mode);
    const run_terminal_ui_cmd = terminal_ui.run();
    run_terminal_ui.dependOn(&run_terminal_ui_cmd.step);

    const run_ui = b.step("run-ui", "Run demonstration of UI");
    const ui = b.addExecutable("ui", "src/ui_api.zig");
    ui.addPackagePath("kisa", "src/kisa.zig");
    ui.setTarget(target);
    ui.setBuildMode(mode);
    const run_ui_cmd = ui.run();
    run_ui.dependOn(&run_ui_cmd.step);

    const test_all = b.step("test", "Run tests");
    const test_main = b.step("test-main", "Run tests in main");
    const test_main_nofork = b.step("test-main-nofork", "Run tests in main without forking");
    const test_state = b.step("test-state", "Run tests in state");
    const test_buffer = b.step("test-buffer", "Run tests in buffer API");
    const test_config = b.step("test-config", "Run tests in config");
    const test_jsonrpc = b.step("test-jsonrpc", "Run tests in jsonrpc");
    const test_transport = b.step("test-transport", "Run tests in transport");
    const test_rpc = b.step("test-rpc", "Run tests in rpc");
    const test_keys = b.step("test-keys", "Run tests in keys");
    const test_ui = b.step("test-ui", "Run tests in UI");

    {
        var test_cases = b.addTest("src/main.zig");
        test_cases.setFilter("main:");
        test_cases.addPackagePath("zzz", "libs/zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
        test_cases.addPackagePath("ziglyph", "libs/ziglyph/src/ziglyph.zig");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_main.dependOn(&test_cases.step);
        test_main_nofork.dependOn(&test_cases.step);
    }

    {
        // Forked tests must be run 1 at a time, otherwise they interfere with other tests.
        var test_cases = b.addTest("src/main.zig");
        test_cases.setFilter("fork/socket:");
        test_cases.addPackagePath("zzz", "libs/zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
        test_cases.addPackagePath("ziglyph", "libs/ziglyph/src/ziglyph.zig");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_main.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/state.zig");
        test_cases.setFilter("state:");
        test_cases.addPackagePath("zzz", "libs/zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
        test_cases.addPackagePath("ziglyph", "libs/ziglyph/src/ziglyph.zig");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_state.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/buffer_api.zig");
        test_cases.setFilter("buffer:");
        test_cases.addPackagePath("ziglyph", "libs/ziglyph/src/ziglyph.zig");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_buffer.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/text_buffer_array.zig");
        test_cases.setFilter("buffer:");
        test_cases.addPackagePath("ziglyph", "libs/ziglyph/src/ziglyph.zig");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_buffer.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/config.zig");
        test_cases.setFilter("config:");
        test_cases.addPackagePath("zzz", "libs/zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_config.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/jsonrpc.zig");
        test_cases.setFilter("jsonrpc:");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_jsonrpc.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/transport.zig");
        test_cases.setFilter("transport/fork1:");
        test_cases.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_transport.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/transport.zig");
        test_cases.setFilter("transport/fork2:");
        test_cases.addPackagePath("known-folders", "libs/known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_transport.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/rpc.zig");
        test_cases.setFilter("myrpc:");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_rpc.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/keys.zig");
        test_cases.setFilter("keys:");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_keys.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/terminal_ui.zig");
        test_cases.setFilter("ui:");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_ui.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/ui_api.zig");
        test_cases.setFilter("ui:");
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
        test_ui.dependOn(&test_cases.step);
    }
}
